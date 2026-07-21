-- Host adapter using luaposix poll/time.
--
-- Optional backend.  This uses posix.time.clock_gettime/nanosleep for time and
-- posix.poll.poll for readiness waits.  It has no persistent kernel state;
-- readiness registrations are rebuilt from the runtime's current waits on each
-- block call.

local Host = require('fibers.host')
local HostError = require('fibers.host.error')
local Provider = require('fibers.host.provider')
local HostWait = require('fibers.host.wait')
local PollPlan = require('fibers.host.poll_plan')
local DatagramProvider = require('fibers.host.datagram_luaposix')
local SocketProvider = require('fibers.host.socket_luaposix')
local ResolverProvider = require('fibers.host.resolver_luaposix')
local ProcessProvider = require('fibers.host.process_luaposix')

local ok_poll, poll_mod = pcall(require, 'posix.poll')
local ok_time, ptime = pcall(require, 'posix.time')
local ok_errno, errno = pcall(require, 'posix.errno')

if
  not ok_poll
  or type(poll_mod) ~= 'table'
  or not ok_time
  or type(ptime) ~= 'table'
  or not ok_errno
  or type(errno) ~= 'table'
then
  return Provider.unsupported(
    'fibers.host.luaposix',
    'requires posix.poll, posix.time and posix.errno',
    { 'new' }
  )
end

local Posix = {}
Posix.__index = Posix

local CLOCK_MONOTONIC = ptime.CLOCK_MONOTONIC
local poll_fn = poll_mod.poll

local function ts_to_seconds(ts)
  return tonumber(ts.tv_sec) + tonumber(ts.tv_nsec) * 1e-9
end

local function monotonic()
  local ts, err = ptime.clock_gettime(CLOCK_MONOTONIC)
  if not ts then
    error('posix.clock_gettime(CLOCK_MONOTONIC) failed: ' .. tostring(err), 2)
  end
  return ts_to_seconds(ts)
end

local function nanosleep(seconds)
  seconds = tonumber(seconds) or 0
  if seconds <= 0 then
    return true
  end
  local sec = math.floor(seconds)
  local nsec = math.floor((seconds - sec) * 1e9 + 0.5)
  if nsec >= 1000000000 then
    sec = sec + 1
    nsec = nsec - 1000000000
  end
  local req = { tv_sec = sec, tv_nsec = nsec }
  while true do
    local ok, err, eno, rem = ptime.nanosleep(req)
    if ok then
      return true
    end
    if eno == errno.EINTR and rem then
      req = rem
    else
      return nil, 'posix.nanosleep failed: ' .. tostring(err or eno)
    end
  end
end

local function fd_of(key)
  if type(key) == 'number' then
    return key
  end
  if type(key) == 'string' and tonumber(key) then
    return tonumber(key)
  end
  if type(key) == 'table' then
    if type(key.fd) == 'number' then
      return key.fd
    end
    if type(key.fileno) == 'function' then
      local ok, fd = pcall(function()
        return key:fileno()
      end)
      if ok and fd ~= nil then
        return tonumber(fd)
      end
    end
  end
  return tonumber(key)
end

function Posix.is_supported()
  return type(poll_fn) == 'function'
    and type(ptime.clock_gettime) == 'function'
    and type(ptime.nanosleep) == 'function'
    and CLOCK_MONOTONIC ~= nil
end

function Posix.new(opts)
  opts = opts or {}
  if not Posix.is_supported() then
    error('fibers.host.luaposix: required luaposix functions are unavailable', 2)
  end
  local self = setmetatable({
    kind = 'luaposix',
    name = 'luaposix',
    family = 'numeric-fd',
    on_wait = opts.on_wait,
    on_wake = opts.on_wake,
    on_unsupported = opts.on_unsupported,
  }, Posix)
  self.now = function(_rt)
    return monotonic()
  end
  self.fd = require('fibers.host.fd_luaposix')
  self.capabilities = {
    time = true,
    readiness = true,
    fd = self.fd.is_supported(),
    pipe = self.fd.is_supported(),
    socket = SocketProvider.is_supported(),
    socket_ipv4 = SocketProvider.supports_ipv4(),
    socket_ipv6 = SocketProvider.supports_ipv6(),
    socket_unix = SocketProvider.supports_unix(),
    datagram = DatagramProvider.is_supported(),
    datagram_truncation = false,
    resolver = ResolverProvider.is_supported(),
    resolver_blocking = ResolverProvider.is_supported(),
    process = ProcessProvider.is_supported(),
    file = ProcessProvider.is_supported(),
    file_backend = ProcessProvider.is_supported() and 'worker' or nil,
    file_io_uring = false,
    file_aio_detected = false,
  }
  return self
end

function Posix:create_pipe(pipe_opts)
  return self.fd.pipe({
    host = self,
    name = pipe_opts and pipe_opts.name,
    nonblocking = pipe_opts == nil or pipe_opts.nonblocking ~= false,
  })
end

function Posix:create_listener(address, listener_opts)
  return SocketProvider.create_listener(self, address, listener_opts)
end

function Posix:start_dial(address, dial_opts)
  return SocketProvider.start_dial(self, address, dial_opts)
end

function Posix:create_datagram(address, datagram_opts)
  return DatagramProvider.create_datagram(self, address, datagram_opts)
end

function Posix:resolve(endpoint, resolve_opts)
  if not ResolverProvider.is_supported() then
    return nil, HostError.unsupported('host', 'resolve', { endpoint = endpoint })
  end
  return ResolverProvider.resolve(self, endpoint, resolve_opts)
end

function Posix:start_process(spec)
  if not ProcessProvider.is_supported() then
    return nil, nil, HostError.unsupported('host', 'process', { host = self.name })
  end
  return ProcessProvider.start_process(self, spec)
end

function Posix:sleep(seconds)
  return nanosleep(seconds)
end

function Posix:block(rt, waits, status, _opts)
  waits = waits or {}
  local deadline = Host.earliest_deadline(waits)
  local plan = PollPlan.build(waits, { key_of = fd_of, fd_of = fd_of })

  if plan.unsupported then
    if self.on_unsupported then
      self.on_unsupported(waits, status)
    end
    return nil, 'unsupported-readiness-key'
  end
  if #plan.records == 0 then
    return HostWait.block_without_io(self, rt, waits, status, deadline)
  end

  local fds = {}
  for i = 1, #plan.records do
    local record = plan.records[i]
    local events = {}
    if record.read then
      events.IN = true
    end
    if record.write then
      events.OUT = true
    end
    fds[record.fd] = { events = events }
  end

  local nready, err, eno = poll_fn(fds, Host.timeout_ms(rt, deadline))
  if nready == nil then
    if eno == errno.EINTR then
      return true, 'poll-interrupted'
    end
    error(tostring(err or eno or 'posix.poll failed'), 2)
  end

  local delivered = false
  if nready > 0 then
    for fd, info in pairs(fds) do
      local revents = info.revents
      if revents then
        local readable = revents.IN or revents.HUP or revents.ERR or revents.NVAL
        local writable = revents.OUT or revents.ERR or revents.NVAL
        if PollPlan.deliver(rt, plan.by_fd[fd], readable, writable) then
          delivered = true
        end
      end
    end
  end
  if delivered then
    return true, 'readiness'
  end
  if deadline ~= nil and rt:now() >= deadline then
    return true, 'time'
  end
  return true, 'poll'
end

function Posix:close()
  -- posix.poll is stateless; there is no persistent host fd to close.
end

return Posix

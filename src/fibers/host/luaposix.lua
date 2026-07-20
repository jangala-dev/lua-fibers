-- Host adapter using luaposix poll/time.
--
-- Optional backend.  This uses posix.time.clock_gettime/nanosleep for time and
-- posix.poll.poll for readiness waits.  It has no persistent kernel state;
-- readiness registrations are rebuilt from the runtime's current waits on each
-- block call.

local Host = require('fibers.host')
local Provider = require('fibers.host.provider')
local HostWait = require('fibers.host.wait')
local DatagramProvider = require('fibers.host.datagram_luaposix')

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
  return Provider.unsupported('fibers.host.luaposix', 'requires posix.poll, posix.time and posix.errno', { 'new' })
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

local function collect_readiness(waits)
  local fds, by_fd, unsupported = {}, {}, false
  local function ensure(fd)
    local rec = by_fd[fd]
    if not rec then
      rec = { fd = fd, events = {}, waits = {}, poller = {} }
      by_fd[fd] = rec
      fds[fd] = { events = rec.events }
    end
    return rec
  end
  local readiness = Host.readiness_waits(waits)
  for i = 1, #readiness do
    local w = readiness[i]
    local fd = fd_of(w.readiness_key)
    if not fd then
      unsupported = true
    else
      local rec = ensure(fd)
      local mode = w.mode or 'read'
      if mode == 'write' or mode == 'wr' then
        rec.events.OUT = true
      else
        rec.events.IN = true
      end
      rec.waits[#rec.waits + 1] = w
    end
  end
  local poller_waits = Host.poller_waits(waits)
  for i = 1, #poller_waits do
    local wait = poller_waits[i]
    local registrations = wait.poller:_host_active()
    for j = 1, #registrations do
      local registration = registrations[j]
      local fd = fd_of(registration.key)
      if not fd then
        unsupported = true
      else
        local rec = ensure(fd)
        if registration.mode == 'write' then
          rec.events.OUT = true
        else
          rec.events.IN = true
        end
        rec.poller[#rec.poller + 1] = { wait = wait, registration = registration }
      end
    end
  end
  return fds, by_fd, unsupported
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
    socket = false,
    socket_ipv4 = false,
    socket_ipv6 = false,
    socket_unix = false,
    datagram = DatagramProvider.is_supported(),
    datagram_truncation = false,
    resolver = false,
    resolver_blocking = false,
    process = false,
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

function Posix:create_datagram(address, datagram_opts)
  return DatagramProvider.create_datagram(self, address, datagram_opts)
end

function Posix:sleep(seconds)
  return nanosleep(seconds)
end

function Posix:block(rt, waits, status, _opts)
  waits = waits or {}
  local deadline = Host.earliest_deadline(waits)
  local fds, by_fd, unsupported = collect_readiness(waits)

  if unsupported then
    if self.on_unsupported then
      self.on_unsupported(waits, status)
    end
    return nil, 'unsupported-readiness-key'
  end

  local have_fd = false
  for _ in pairs(by_fd) do
    have_fd = true
    break
  end

  if not have_fd then
    return HostWait.block_without_io(self, rt, waits, status, deadline)
  end

  local timeout_ms = Host.timeout_ms(rt, deadline)
  local nready, err, eno = poll_fn(fds, timeout_ms)
  if nready == nil then
    if eno == errno.EINTR then
      return true, 'poll-interrupted'
    end
    error(tostring(err or eno or 'posix.poll failed'), 2)
  end

  local delivered = false
  if nready > 0 then
    for fd, info in pairs(fds) do
      local re = info.revents
      if re then
        local rd = re.IN or re.HUP or re.ERR or re.NVAL
        local wr = re.OUT or re.ERR or re.NVAL
        local rec = by_fd[fd]
        if rec then
          for i = 1, #rec.waits do
            local w = rec.waits[i]
            local mode = w.mode or 'read'
            if (mode == 'write' or mode == 'wr') and wr then
              rt:deliver(w.feed, 'write', true)
              delivered = true
            elseif mode ~= 'write' and mode ~= 'wr' and rd then
              rt:deliver(w.feed, 'read', true)
              delivered = true
            end
          end
          for i = 1, #rec.poller do
            local item = rec.poller[i]
            local registration = item.registration
            local ready = registration.mode == 'write' and wr or rd
            if ready and item.wait.poller:_host_delivered(registration) then
              Host.deliver_poller_ready(rt, item.wait, registration)
              delivered = true
            end
          end
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

-- Linux host adapter using neopallium's nixio.
--
-- This adapter is optional.  It uses nixio.gettime/nanosleep for time and
-- nixio.poll for readiness waits.  Requiring the module without nixio succeeds;
-- is_supported() returns false and new() raises a clear error.

local Host = require('fibers.host')
local HostError = require('fibers.host.error')
local Provider = require('fibers.host.provider')
local HostWait = require('fibers.host.wait')
local PollPlan = require('fibers.host.poll_plan')
local NixioPoll = require('fibers.host.nixio_poll')
local DatagramProvider = require('fibers.host.datagram_nixio')
local SocketProvider = require('fibers.host.socket_nixio')
local ResolverProvider = require('fibers.host.resolver_nixio')
local ProcessProvider = require('fibers.host.process_nixio')

local ok_nixio, nixio = pcall(require, 'nixio')
if not ok_nixio or type(nixio) ~= 'table' then
  return Provider.unsupported('fibers.host.nixio', 'requires nixio', { 'new' })
end

local Nixio = {}
Nixio.__index = Nixio

local function read_uptime()
  local f = io.open('/proc/uptime', 'r')
  if not f then
    return nil
  end
  local line = f:read('*l')
  f:close()
  local first = line and line:match('^%s*(%S+)')
  return first and tonumber(first) or nil
end

local function monotonic()
  return read_uptime() or nixio.gettime()
end

local function nanosleep(seconds)
  seconds = tonumber(seconds) or 0
  if seconds <= 0 then
    return true
  end
  local deadline = monotonic() + seconds
  while true do
    local remaining = deadline - monotonic()
    if remaining <= 0 then
      return true
    end
    local sec = math.floor(remaining)
    local nsec = math.floor((remaining - sec) * 1e9 + 0.5)
    if nsec >= 1000000000 then
      sec = sec + 1
      nsec = nsec - 1000000000
    end
    local ok, err, eno = nixio.nanosleep(sec, nsec)
    if not ok then
      local msg = tostring(err or eno or '')
      -- nixio reports EINTR differently across versions; recomputing the
      -- remaining time is safe for interruptions and soft failures.
      if msg ~= '' and msg ~= 'EINTR' and msg ~= 'interrupted system call' then
        return nil, 'nixio.nanosleep failed: ' .. msg
      end
    end
  end
end

local function poll_key(key)
  if type(key) == 'table' then
    return key.handle or key.nixio or key
  end
  return key
end

function Nixio.is_supported()
  return type(nixio.gettime) == 'function'
    and type(nixio.nanosleep) == 'function'
    and type(nixio.poll) == 'function'
    and type(nixio.poll_flags) == 'function'
end

function Nixio.new(opts)
  opts = opts or {}
  if not Nixio.is_supported() then
    error('fibers.host.nixio: required nixio functions are unavailable', 2)
  end
  local self = setmetatable({
    kind = 'nixio',
    name = 'nixio',
    family = 'nixio',
    on_wait = opts.on_wait,
    on_wake = opts.on_wake,
    on_unsupported = opts.on_unsupported,
  }, Nixio)
  self.now = function(_rt)
    return monotonic()
  end
  self.fd = require('fibers.host.fd_nixio')
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
    process_exec_proof = false,
    process_pass_fds = false,
    process_close_fds = 'known',
    process_groups = 'session',
  }
  return self
end

function Nixio:create_pipe(pipe_opts)
  return self.fd.pipe({
    host = self,
    name = pipe_opts and pipe_opts.name,
    nonblocking = pipe_opts == nil or pipe_opts.nonblocking ~= false,
  })
end

function Nixio:create_listener(address, listener_opts)
  return SocketProvider.create_listener(self, address, listener_opts)
end

function Nixio:start_dial(address, dial_opts)
  return SocketProvider.start_dial(self, address, dial_opts)
end

function Nixio:create_datagram(address, datagram_opts)
  return DatagramProvider.create_datagram(self, address, datagram_opts)
end

function Nixio:start_process(spec)
  if not ProcessProvider.is_supported() then
    return nil, nil, HostError.unsupported('host', 'process', { host = self.name })
  end
  return ProcessProvider.start_process(self, spec)
end

function Nixio:resolve(endpoint, resolve_opts)
  if not ResolverProvider.is_supported() then
    return nil, HostError.unsupported('host', 'resolve', { endpoint = endpoint })
  end
  return ResolverProvider.resolve(self, endpoint, resolve_opts)
end

function Nixio:sleep(seconds)
  return nanosleep(seconds)
end

function Nixio:block(rt, waits, status, _opts)
  waits = waits or {}
  local deadline = Host.earliest_deadline(waits)
  local plan = PollPlan.build(waits, {
    key_of = poll_key,
    fd_of = NixioPoll.descriptor_number,
  })

  if plan.unsupported then
    if self.on_unsupported then
      self.on_unsupported(waits, status)
    end
    return nil, 'unsupported-readiness-key'
  end
  if #plan.records == 0 then
    return HostWait.block_without_io(self, rt, waits, status, deadline)
  end

  local ready = NixioPoll.run(nixio, plan, Host.timeout_ms(rt, deadline))
  if not ready then
    return true, 'poll-interrupted'
  end

  local delivered = false
  for i = 1, #ready do
    local item = ready[i]
    if PollPlan.deliver(rt, item.record, item.read, item.write) then
      delivered = true
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

function Nixio:close()
  -- nixio.poll is stateless; no persistent host descriptor to close.
end

return Nixio

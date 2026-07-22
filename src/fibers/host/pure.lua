-- Deliberately small pure-Lua host adapter.
--
-- This adapter supports time waits only.  It uses os.time by default for the
-- host clock and os.execute("sleep N") when the host exposes it.  Sandboxed
-- runtimes such as the standalone Luau CLI must supply opts.sleep explicitly.
-- It does not support file descriptor polling or arbitrary host events.

local WaitSet = require('fibers.host.wait_set')

local Pure = {}
Pure.__index = Pure

local function default_now()
  return os.time()
end

local function default_sleep(seconds)
  seconds = tonumber(seconds) or 0
  if seconds <= 0 then
    return true
  end
  local whole = math.ceil(seconds)
  if whole <= 0 then
    return true
  end
  local execute = os and os.execute
  if type(execute) ~= 'function' then
    return nil, 'pure host cannot sleep: os.execute is unavailable; supply opts.sleep'
  end
  return execute('sleep ' .. tostring(whole))
end

function Pure.new(opts)
  opts = opts or {}
  local now = opts.now or default_now
  local sleep = opts.sleep or default_sleep
  local self = setmetatable({
    kind = 'pure',
    name = 'pure',
    family = 'pure',
    on_wait = opts.on_wait,
    on_wake = opts.on_wake,
    on_unsupported = opts.on_unsupported,
    _now = now,
    _sleep = sleep,
  }, Pure)

  -- Runtime:now calls host.now(runtime), so expose now as a plain function using
  -- the host's private closure rather than relying on colon dispatch.
  self.now = function(_rt)
    return now()
  end

  self.capabilities = {
    time = true,
    readiness = false,
    fd = false,
    pipe = false,
    socket = false,
    socket_ipv4 = false,
    socket_ipv6 = false,
    socket_unix = false,
    datagram = false,
    resolver = false,
    resolver_blocking = false,
    file = false,
    file_backend = nil,
    file_io_uring = false,
    file_aio_detected = false,
    process = false,
  }
  return self
end

function Pure:sleep(seconds)
  return self._sleep(seconds)
end

function Pure:block(rt, waits, status, _opts)
  return WaitSet.block_without_io(self, rt, WaitSet.build(waits), status)
end

return Pure

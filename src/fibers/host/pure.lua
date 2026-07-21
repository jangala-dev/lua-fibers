-- Deliberately small pure-Lua host adapter.
--
-- This adapter supports time waits only.  It uses os.time by default for the
-- host clock and os.execute("sleep N") to avoid busy-waiting.  It does not
-- support file descriptor polling or arbitrary host events.

local Host = require('fibers.host')

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
  return os.execute('sleep ' .. tostring(whole))
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
  waits = waits or {}
  local deadline = Host.earliest_deadline(waits)
  if deadline ~= nil then
    local now = rt:now()
    local delay = deadline - now
    if delay > 0 then
      if self.on_wait then
        self.on_wait(deadline, delay, waits, status)
      end
      self:sleep(delay)
      if self.on_wake then
        self.on_wake(deadline, waits, status)
      end
    end
    return true, 'time'
  end

  if self.on_unsupported then
    self.on_unsupported(waits, status)
  end
  return nil, 'unsupported-waits'
end

return Pure

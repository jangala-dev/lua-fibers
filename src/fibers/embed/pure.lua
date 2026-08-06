-- Deliberately small pure-Lua host.
--
-- This adapter supports time waits only.  It uses os.time by default for the
-- host clock and os.execute("sleep N") when the host exposes it.  Sandboxed
-- runtimes such as the standalone Luau CLI must supply opts.sleep explicitly.
-- It does not support file descriptor polling or arbitrary host events.

local WaitSet = require('fibers.embed.wait_set')
local Label = require('fibers.internal.label')

local next_pure = 0

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
  next_pure = next_pure + 1
  local self = Label.attach(setmetatable({
    _fibers_id = 'pure-host-' .. tostring(next_pure),
    kind = 'pure',
    family = 'pure',
    _now = now,
    _sleep = sleep,
  }, Pure), opts.label)

  -- Runtime:now calls host.now(runtime), so expose now as a plain function using
  -- the host's private closure rather than relying on colon dispatch.
  self.now = function(_rt)
    return now()
  end

  self.capabilities = { time = true }
  return self
end

function Pure:sleep(seconds)
  return self._sleep(seconds)
end

function Pure:block(rt, waits, status, _opts)
  return WaitSet.block_without_io(self, rt, WaitSet.build(waits), status)
end

return Pure

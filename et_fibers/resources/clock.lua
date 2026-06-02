local core = require('etfcore')
local Op = core.Op

-- --------------------------------------------------------------------------
-- Clock resource: external readiness for deadlines.
--
-- sleep_until_op(deadline) returns an external-await operation.  sleep_op(dt)
-- uses guard so the relative deadline is fixed when an attempt reaches the
-- operation, not when the Lua value is constructed and not on proof replay.
-- --------------------------------------------------------------------------

local Clock = {}
Clock.__index = Clock

function Clock.new(runtime, opts)
  opts = opts or {}
  local self = setmetatable({
    runtime = runtime,
    name = opts.name or 'clock',
    now_fn = opts.now_fn or os.clock,
    sleep_fn = opts.sleep_fn,
    waits = {},
  }, Clock)
  if runtime and runtime.register_external_source then
    runtime:register_external_source(self)
  end
  return self
end

function Clock:now()
  return self.now_fn()
end

function Clock:sleep_until_op(deadline)
  return Op.await(self, { tag = 'deadline', deadline = deadline })
end

function Clock:sleep_op(delay)
  return Op.guard(function()
    return self:sleep_until_op(self:now() + delay)
  end)
end

function Clock:ready(request, _runtime)
  if request.tag ~= 'deadline' then return false end
  if self:now() >= request.deadline then
    return true, { value = true }
  end
  return false
end

local function prune_cancelled(self)
  local write = 1
  for read = 1, #self.waits do
    local token = self.waits[read]
    if not token.cancelled then
      self.waits[write] = token
      write = write + 1
    end
  end
  for i = write, #self.waits do self.waits[i] = nil end
end

function Clock:publish_wait(runtime, attempt, frame)
  local token = {
    attempt = attempt,
    request = frame.request,
    deadline = frame.request.deadline,
    cancelled = false,
  }
  self.waits[#self.waits + 1] = token
  if runtime and runtime.register_external_source then
    runtime:register_external_source(self)
  end
  return token
end

function Clock:unpublish_wait(_runtime, token)
  if token then token.cancelled = true end
end

function Clock:next_deadline(_runtime)
  prune_cancelled(self)
  local best = nil
  for _, token in ipairs(self.waits) do
    if not token.cancelled and (not best or token.deadline < best) then
      best = token.deadline
    end
  end
  return best
end

function Clock:poll(_runtime)
  prune_cancelled(self)
  local now = self:now()
  for _, token in ipairs(self.waits) do
    if not token.cancelled and now >= token.deadline then
      return true
    end
  end
  return false
end

function Clock:wait(runtime, timeout, deadline)
  local dt = timeout
  if dt == nil and deadline ~= nil then
    dt = deadline - self:now()
    if dt < 0 then dt = 0 end
  end

  if self.sleep_fn and dt ~= nil and dt > 0 then
    self.sleep_fn(dt)
  end

  return self:poll(runtime)
end

return Clock

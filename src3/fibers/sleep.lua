-- fibers/sleep.lua
--
-- Sleep as Ops that register runtime timers and wait via Pulse.

local runtime = require 'fibers.runtime'
local op      = require 'fibers.op'

local new_primitive = op.new_primitive

local function cancel_timer(self)
  local h = self.handle
  if h then
    runtime.timer_cancel(h)
    self.handle = nil
  end
end

local function sleep_poll(self, ctx, out)
  if self.done then
    if out then out.n = 0 end
    return true
  end

  -- Single-fibre use.
  if self.waker and self.waker ~= ctx.waker then
    error('sleep op used from a different fibre', 0)
  end
  self.waker = ctx.waker

  if runtime.now() >= self.deadline then
    if out then out.n = 0 end
    return true
  end

  -- Register interest once.
  if not self.handle then
    self.handle = runtime.timer_at(self.deadline, self.waker)
  end

  return false
end

local function sleep_commit(self, _)
  if self.done then return end
  self.done = true
  cancel_timer(self)
  self.waker = nil
end

local function sleep_rollback(self, _, _)
  if self.done then return end
  cancel_timer(self)
  self.waker = nil
end

local function sleep_until_op(t_abs)
  if type(t_abs) ~= 'number' then error('sleep_until_op expects a number', 2) end

  return new_primitive(sleep_poll, sleep_commit, sleep_rollback, {
    done     = false,
    deadline = t_abs,
    handle   = nil,
    waker    = nil,
  })
end

local function sleep_op(dt)
  if type(dt) ~= 'number' or dt < 0 then
    error('sleep_op expects a non-negative number of seconds', 2)
  end
  return op.guard(function ()
    return sleep_until_op(runtime.now() + dt)
  end)
end

local function sleep(dt)
  return op.perform(sleep_op(dt))
end

local function sleep_until(t_abs)
  return op.perform(sleep_until_op(t_abs))
end

return {
  sleep          = sleep,
  sleep_op       = sleep_op,
  sleep_until    = sleep_until,
  sleep_until_op = sleep_until_op,
}

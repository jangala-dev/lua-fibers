-- Sleep facility.
--
-- Sleep is ordinary option syntax built over a clock resource.  Absolute sleep
-- is a clock-resource wait.  Relative sleep is a guard that fixes its absolute
-- deadline once for the perform attempt.

local Op = require('fibers.op')
local Clock = require('fibers.resource.clock')
local perform = require('fibers.perform')

local Sleep = {}

local clock = Clock.new('sleep')

local function assert_finite_number(x, name)
  if type(x) ~= 'number' or x ~= x or x == math.huge or x == -math.huge then
    error(name .. ' must be a finite number', 3)
  end
  return x
end

function Sleep.now_op()
  return clock:now_op()
end

function Sleep.sleep_until_op(t)
  assert_finite_number(t, 'sleep_until_op deadline')
  return clock:at_op(t)
end

function Sleep.sleep_op(d)
  assert_finite_number(d, 'sleep_op delay')
  return Op.guard(function(ctx)
    if not ctx or type(ctx.now) ~= 'function' then
      error('sleep_op requires an attempt context with a runtime clock', 2)
    end
    return Sleep.sleep_until_op(ctx:now() + d)
  end)
end

function Sleep.sleep_until(t)
  return perform(Sleep.sleep_until_op(t))
end

function Sleep.sleep(d)
  return perform(Sleep.sleep_op(d))
end

return Sleep

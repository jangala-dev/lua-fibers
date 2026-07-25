-- Sleep vocabulary over the default monotonic Clock.
--
-- Clock owns the time algebra. Sleep retains the familiar direct and option
-- names as a small convenience facade.

local Clock = require('fibers.resource.clock')
local perform = require('fibers.perform')

local Sleep = {}
local clock = Clock.default()

local function sleep_result(observed_at)
  return true, observed_at
end

function Sleep.sleep_until_op(deadline)
  return clock:at_op(deadline):map(sleep_result)
end

function Sleep.sleep_op(delay)
  return clock:after_op(delay):map(sleep_result)
end

function Sleep.sleep_until(deadline)
  return perform(Sleep.sleep_until_op(deadline))
end

function Sleep.sleep(delay)
  return perform(Sleep.sleep_op(delay))
end

return Sleep

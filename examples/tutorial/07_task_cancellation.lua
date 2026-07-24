package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

-- Cancellation is an explicit request to an owned task. An emergency stop
-- reaches the robot motion planner at a Fibers suspension boundary and leaves
-- an inspectable exit.

local fibers = require('fibers')
local Signal = require('fibers.resource.signal')

local planner_exit

fibers.run(function(scope)
  local waiting_for_clearance = Signal.new('motion-clearance')
  local planner = scope:spawn(function()
    fibers.perform(waiting_for_clearance:wait_op())
    return 'unreachable'
  end, 'robot-motion-planner')

  local first, reason = planner:request_cancel('emergency stop pressed')
  assert(first == true)
  assert(reason == 'emergency stop pressed')

  planner_exit = fibers.perform(planner:exit_op())
end)

assert(planner_exit.tag == 'cancelled' or planner_exit.tag == 'failed')
print('motion planner exit:', planner_exit.tag, planner_exit.reason or planner_exit.error)

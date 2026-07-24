package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

-- Cancellation is an explicit request to an owned task. The task observes it at
-- a Fibers suspension boundary and its exit remains available for inspection.

local fibers = require('fibers')
local Signal = require('fibers.resource.signal')

local task_exit

fibers.run(function(scope)
  local blocked = Signal.new('blocked-worker')
  local task = scope:spawn(function()
    fibers.perform(blocked:wait_op())
    return 'unreachable'
  end, 'worker')

  local first, reason = task:request_cancel('shutdown requested')
  assert(first == true)
  assert(reason == 'shutdown requested')

  task_exit = fibers.perform(task:exit_op())
end)

assert(task_exit.tag == 'cancelled' or task_exit.tag == 'failed')
print('task exit:', task_exit.tag, task_exit.reason or task_exit.error)

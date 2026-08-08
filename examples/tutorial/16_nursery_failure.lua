package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

-- Nursery Closure is fail-fast. If the authoritative flood controller fails,
-- the blocked public-warning sibling and the incident body are cancelled and
-- joined before the boundary returns.

local fibers = require('fibers')
local Runtime = require('fibers.runtime')
local Signal = require('fibers.resource.signal')

local warning_task, incident_cancelled

local result = fibers.try_run(function()
  local incident_never_finishes = Signal.new():label('incident-never-finishes')

  warning_task = fibers.spawn(function()
    fibers.perform(incident_never_finishes:wait_op())
  end):label('public-warning-feed')

  fibers.spawn(function()
    error('flood model lost its active catchment state', 0)
  end):label('flood-controller')

  local ok, err = fibers.pcall(function()
    fibers.perform(incident_never_finishes:wait_op())
  end)
  incident_cancelled = not ok and Runtime.is_cancelled(err)
end)

assert(result.ok == false)
assert(result.reason == 'child_failed')
assert(incident_cancelled == true)
assert(#result.report.child_failures == 1)

local warning_exit
fibers.run(function()
  warning_exit = fibers.perform(warning_task:body_result_op())
end)
assert(warning_exit.tag == 'cancelled')

print('incident:', result.reason, 'warning feed:', warning_exit.tag)

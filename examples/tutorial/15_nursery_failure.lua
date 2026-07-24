package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

-- Nursery policy is fail-fast. A failed child interrupts the blocked body,
-- cancels its siblings, joins them and retains the causal failure in the report.

local fibers = require('fibers')
local Runtime = require('fibers.runtime')
local Signal = require('fibers.resource.signal')

local sibling, body_cancelled

local result = fibers.try_run(function()
  local never = Signal.new('nursery-never')

  sibling = fibers.spawn(function()
    fibers.perform(never:wait_op())
  end, 'blocked-sibling')

  fibers.spawn(function()
    error('sensor failed', 0)
  end, 'failing-child')

  local ok, err = fibers.pcall(function()
    fibers.perform(never:wait_op())
  end)
  body_cancelled = not ok and Runtime.is_cancelled(err)
end)

assert(result.ok == false)
assert(result.reason == 'child_failed')
assert(body_cancelled == true)
assert(#result.report.child_failures == 1)

local sibling_state
fibers.run(function()
  sibling_state = fibers.perform(sibling:state_op())
end)
assert(sibling_state.exited)
assert(sibling_state.exit.tag == 'cancelled')

print('scope result:', result.reason, 'sibling:', sibling_state.exit.tag)

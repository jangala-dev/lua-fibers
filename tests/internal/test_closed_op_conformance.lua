package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

local fibers = require('fibers')
local Completion = require('fibers.resource.completion')
local IO = require('fibers.io.facility')
local Op = require('fibers.op')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'values differ') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual), 2)
  end
end

-- The common host-facility closure join must not equate an early public terminal
-- event with complete settlement of the private structured driver.
do
  local descendant_finished = false
  local observed
  fibers.run(function(scope)
    local terminal = Completion.new('driver-closure-terminal')
    local release_descendant = Completion.new('driver-closure-release-descendant')
    local driver = fibers.perform(scope:spawn_op(function(driver_scope)
      driver_scope:spawn(function()
        fibers.perform(release_descendant:success_op())
        descendant_finished = true
      end, 'delayed-driver-descendant')
      fibers.perform(terminal:publish_success_op('terminal'))
      return true
    end, { name = 'conformance-driver' }))

    scope:spawn(function()
      fibers.perform(terminal:success_op())
      assert(not descendant_finished, 'private descendant finished before the public terminal event')
      fibers.perform(release_descendant:publish_success_op(true))
    end, 'release-delayed-driver-descendant')

    observed = fibers.perform(IO.closed_after_driver_op(driver, terminal:success_op(), {
      require_returned = true,
    }))
    assert(descendant_finished, 'closed_after_driver_op returned before the private descendant retired')
  end)
  assert_eq(observed, 'terminal')
end

-- Facilities without a private driver still retain their terminal operation's
-- values and do not gain a synthetic lifecycle.
do
  local value = fibers.run(function()
    return fibers.perform(IO.closed_after_driver_op(nil, Op.always('closed')))
  end)
  assert_eq(value, 'closed')
end

-- Misconstructed facility closure operations fail at construction.
do
  assert(not pcall(IO.closed_after_driver_op, {}, Op.always(true)))
  assert(not pcall(IO.closed_after_driver_op, nil, true))
  assert(not pcall(IO.closed_after_driver_op, nil, Op.always(true), true))
  assert(not pcall(IO.closed_after_driver_op, nil, Op.always(true), { require_returned = 'yes' }))
end

print('tests/internal/test_closed_op_conformance.lua: ok')

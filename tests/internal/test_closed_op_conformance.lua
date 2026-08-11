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

-- The common host-facility closure join observes the driver's local
-- computation and any domain terminal event. Descendant retirement remains a
-- separate Lifetime obligation and must not be folded back into the local
-- close protocol.
do
  local descendant_finished = false
  local observed
  fibers.run(function(scope)
    local terminal = Completion.new():label('driver-closure-terminal')
    local release_descendant = Completion.new():label('driver-closure-release-descendant')
    local driver = fibers.perform(scope:spawn_op(function(driver_scope)
      driver_scope:spawn(function()
        fibers.perform(release_descendant:success_op())
        descendant_finished = true
      end):label('delayed-driver-descendant')
      fibers.perform(terminal:publish_success_op('terminal'))
      return true
    end, { label = 'conformance-driver' }))

    observed = fibers.perform(IO.closed_after_driver_op(driver, terminal:success_op(), {
      require_returned = true,
    }))
    assert(not descendant_finished,
      'local driver closure should not wait for private descendant retirement')
    fibers.perform(release_descendant:publish_success_op(true))
    driver:await()
    assert(descendant_finished, 'driver Lifetime should still account for its descendant')
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

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
local FibersRuntime = require('fibers.runtime')
local Lifetimes = require('tests.support.lifetimes')
local function assert_eq(a, b, msg)
  if a ~= b then
    error((msg or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2)
  end
end

-- Lifetime topology change observation is a managed transactional fact.
do
  local rt = FibersRuntime.new()
  local scope = Lifetimes.scope(rt, 'changed-scope')
  local first, changed
  rt:spawn_raw(function()
    first = rt:perform(scope:_store():status_op(scope))
    rt:perform(scope:admit_op(Lifetimes.resource('changed-item')))
    changed = rt:perform(scope:_store():changed_op(scope, first.version))
  end, 'lifetime-change')
  repeat
  until rt:run().tag ~= 'found'
  assert_eq(changed, first.version + 1)
end

-- Cancellation is monotonic and preserves the first cause.
do
  fibers.run(function(scope)
    local first, second, requested, reason
    fibers.mask(function()
      first, reason = fibers.perform(scope:request_cancel_op('first'))
      second = fibers.perform(scope:request_cancel_op('second'))
      requested, reason = fibers.perform(scope:cancel_requested_op())
    end)
    assert_eq(first, true)
    assert_eq(second, false)
    assert_eq(requested, true)
    assert_eq(reason, 'first')
  end)
end

-- Task cancellation follows the same first-reason rule.
do
  local task
  fibers.run(function(scope)
    task = fibers.perform(scope:spawn_op(function() end, 'cancel-fact'))
    local first, reason = fibers.perform(task:request_cancel_op('first'))
    local second = fibers.perform(task:request_cancel_op('second'))
    local requested
    requested, reason = fibers.perform(task:cancel_requested_op())
    assert_eq(first, true)
    assert_eq(second, false)
    assert_eq(requested, true)
    assert_eq(reason, 'first')
  end)
end

print('tests/test_scope_closure_mechanisms.lua: ok')

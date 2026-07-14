package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './reference/?.lua',
  './reference/?/init.lua',
  './reference/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

local fibers = require('fibers')
local FibersRuntime = require('fibers.runtime')
local FibersRegion = require('fibers.lifetime.region')
local FibersTask = require('fibers.task')

local function assert_eq(a, b, msg)
  if a ~= b then
    error((msg or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2)
  end
end

-- Region change observation is a managed transactional fact.
do
  local rt = FibersRuntime.new()
  local region = FibersRegion.new('changed-region')
  local first, changed
  rt:spawn_raw(function()
    first = rt:perform(region:snapshot_op())
    rt:perform(region:admit_op(FibersRegion.handle('changed-item')))
    changed = rt:perform(region:changed_op(first.version))
  end, 'region-change')
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
    task = FibersTask.new(function() end, 'cancel-fact', scope)
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

print('tests/test_scope_policy_mechanisms.lua: ok')

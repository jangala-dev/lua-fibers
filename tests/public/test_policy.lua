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
local FibersRendezvous = require('fibers.resource.rendezvous')
local FibersSignal = require('fibers.external.signal')
local FibersPolicy = require('fibers.policy')

local function fail(msg)
  error(msg, 2)
end
local function assert_eq(a, b, msg)
  if a ~= b then
    fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a))
  end
end
local function assert_truthy(v, msg)
  if not v then
    fail(msg or 'expected truthy')
  end
end
local function assert_status(st, tag, msg)
  if not st or st.tag ~= tag then
    fail(
      (msg or 'status mismatch')
        .. ': expected '
        .. tostring(tag)
        .. ', got '
        .. tostring(st and st.tag)
    )
  end
end

-- The friendly spawn name uses the current root scope installed by fibers.run.
do
  local child
  local st = fibers.try_run(function()
    child = fibers.spawn(function()
      return 'ok'
    end)
    local exit = fibers.perform(child:exit_op())
    assert_eq(exit.tag, 'returned')
  end).runtime_status
  assert_truthy(
    st.tag == 'found' or st.tag == 'pending' or st.tag == 'idle',
    'unexpected status: ' .. tostring(st.tag)
  )
  assert_truthy(child, 'fibers.spawn should return a task handle under the root scope')
end

-- A custom nursery policy is now passed to run/try_run; it is not a separate
-- launch path.
do
  local got, child
  local r = fibers.try_run(function(scope)
    local ch = FibersRendezvous.new('policy-rendezvous')
    child = fibers.spawn(function()
      fibers.perform(ch:put_op('hello'))
    end, 'sender')
    got = fibers.perform(ch:get_op())
    assert_truthy(scope:raw_region(), 'root scope should expose its Region to compound authors')
  end, { policy = FibersPolicy.nursery() })
  assert_truthy(r.ok, tostring(r.report or r.reason))
  assert_eq(got, 'hello')
  assert_truthy(child, 'nursery spawn should return a task handle')
end

-- Direct cancellation is task-level. Scope policy uses the same task/resource
-- protocols internally during settlement.
do
  local task
  local r = fibers.try_run(function()
    local src = FibersSignal.new('policy-cancel-source')
    task = fibers.spawn(function()
      fibers.perform(src:wait_op())
    end, 'waiter')
    fibers.perform(task:request_cancel_op('stop'))
    local exit = fibers.perform(task:exit_op())
    assert_truthy(
      exit.tag == 'cancelled' or exit.tag == 'failed',
      'explicit cancellation should end the task'
    )
  end, { policy = FibersPolicy.nursery() })
  assert_truthy(r.ok, tostring(r.report or r.reason))
end

-- Body failure cancels owned children before the nursery reports the body error.
do
  local child
  local r = fibers.try_run(function()
    local src = FibersSignal.new('policy-body-failure-source')
    child = fibers.spawn(function()
      fibers.perform(src:wait_op())
    end, 'owned-waiter')
    error('body failed')
  end, { policy = FibersPolicy.nursery() })
  assert_eq(r.ok, false)
  assert_eq(r.reason, 'body_error')
  assert_truthy(tostring(r.primary):match('body failed'))

  local state
  local st = fibers.try_run(function()
    state = fibers.perform(child:state_op())
  end).runtime_status
  assert_status(st, 'found', 'status after inspecting cancelled child')
  assert_truthy(
    state.exit.tag == 'cancelled' or state.exit.tag == 'failed',
    'child should be cancelled or report scope failure under body failure'
  )
end

-- A custom policy owns the boundary algorithm and may delegate to the shared
-- mechanism driver explicitly.
do
  local entered = false
  local policy = {
    name = 'custom-boundary',
    permit_unstructured = false,
    permit_outward_move = true,
    permit_admission = true,
    try_run = function(self, scope, fn, driver)
      entered = true
      return driver.run(scope, fn, self)
    end,
  }
  local r = fibers.try_run(function()
    return 'custom-ok'
  end, { policy = policy })
  assert_truthy(r.ok, tostring(r.report or r.reason))
  assert_eq(r:unpack(), 'custom-ok')
  assert_truthy(entered, 'custom policy try_run should own the boundary')
end

print('tests/test_policy.lua: ok')

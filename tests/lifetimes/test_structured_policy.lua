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
local FibersRendezvous = require('fibers.resource.rendezvous')
local FibersSignal = require('fibers.external.signal')
local FibersRegion = require('fibers.lifetime.region')
local FibersPolicy = require('fibers.policy')

local function assert_eq(a, b, msg)
  if a ~= b then
    error((msg or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2)
  end
end
local function assert_truthy(v, msg)
  if not v then
    error(msg or 'expected truthy', 2)
  end
end

-- Nursery failure is live: it interrupts a blocked body and cancels siblings.
do
  local sibling
  local body_cancelled = false
  local r = fibers.try_run(function()
    local never = FibersSignal.new('structured-never')
    sibling = fibers.spawn(function()
      fibers.perform(never:wait_op())
    end, 'blocked-sibling')
    fibers.spawn(function()
      error('live child boom', 0)
    end, 'failing-child')
    local ok, err = fibers.pcall(function()
      fibers.perform(never:wait_op())
    end)
    body_cancelled = not ok and FibersRuntime.is_cancelled(err)
  end)
  assert_eq(r.ok, false)
  assert_eq(r.reason, 'child_failed')
  assert_truthy(body_cancelled, 'nursery should interrupt a blocked body promptly')
  assert_truthy(r.report and #r.report.child_failures == 1, 'child failure should be retained')

  local state
  fibers.run(function()
    state = fibers.perform(sibling:state_op())
  end)
  assert_truthy(state.exited, 'sibling should be joined')
  assert_eq(state.exit.tag, 'cancelled', 'sibling should be cancelled by nursery failure')
end

-- Supervisor failure does not interrupt the body or cancel successful siblings.
do
  local body_completed = false
  local sibling_completed = false
  local r = fibers.try_run(function()
    return fibers.try_scope(
      { policy = FibersPolicy.supervisor({ child_failure = 'fail_at_exit' }) },
      function()
        local ready = FibersRendezvous.new('supervisor-ready')
        fibers.spawn(function()
          error('supervised boom', 0)
        end, 'supervised-failure')
        fibers.spawn(function()
          sibling_completed = true
          fibers.perform(ready:put_op(true))
        end, 'supervised-sibling')
        fibers.perform(ready:get_op())
        body_completed = true
        return 'body-value'
      end
    )
  end)
  assert_truthy(r.ok, 'outer root should return the inner result')
  local inner = r.values[1]
  assert_eq(inner.ok, false)
  assert_eq(inner.reason, 'child_failed')
  assert_truthy(body_completed, 'supervisor should not interrupt its body')
  assert_truthy(sibling_completed, 'supervisor should not cancel successful siblings')
end

-- Collecting supervisors retain child failures without failing the boundary.
do
  local r = fibers.try_run(function()
    return fibers.try_scope({ policy = FibersPolicy.supervisor({ child_failure = 'collect' }) }, function()
      fibers.spawn(function()
        error('collected boom', 0)
      end)
      return 42
    end)
  end)
  assert_truthy(r.ok)
  local inner = r.values[1]
  assert_truthy(inner.ok, 'collecting supervisor should succeed')
  assert_eq(inner:unpack(), 42)
  assert_truthy(
    inner.report and #inner.report.child_failures == 1,
    'collected failure should remain in the report'
  )
  assert_truthy(
    tostring(inner.report):match('completed with 1 child failure') ~= nil,
    'successful collection report should not claim the scope failed'
  )
end

-- The high-level raw spawn escape is denied by default but can be enabled by policy.
do
  local denied, allowed = false, false
  fibers.run(function()
    local ok, err = pcall(function()
      fibers.spawn_raw(function() end)
    end)
    denied = not ok and tostring(err):match('prohibited') ~= nil
  end)
  fibers.run(function()
    fibers.spawn_raw(function()
      allowed = true
    end)
  end, { policy = FibersPolicy.nursery({ allow_unstructured = true }) })
  assert_truthy(denied, 'nursery should reject high-level unstructured spawn')
  assert_truthy(allowed, 'policy should be able to permit unstructured spawn explicitly')
end

-- Cancellation of a child scope propagates through its policy to grandchildren.
do
  local child, grandchild
  local r = fibers.try_run(function()
    local never = FibersSignal.new('nested-cancel-never')
    child = fibers.spawn(function()
      grandchild = fibers.spawn(function()
        fibers.perform(never:wait_op())
      end, 'grandchild')
      fibers.perform(never:wait_op())
    end, 'child-with-grandchild')
    fibers.spawn(function()
      error('parent failure', 0)
    end, 'parent-failure')
  end)
  assert_eq(r.ok, false)
  assert_eq(r.reason, 'child_failed')

  local child_state, grandchild_state
  fibers.run(function()
    child_state = fibers.perform(child:state_op())
    grandchild_state = fibers.perform(grandchild:state_op())
  end)
  assert_eq(child_state.exit.tag, 'cancelled')
  assert_eq(grandchild_state.exit.tag, 'cancelled')
end

-- A strict movement policy can prohibit custody escape while leaving Region as
-- the explicit low-level mechanism.
do
  local denied = false
  fibers.run(function(root)
    local h = FibersRegion.handle('strict-move')
    fibers.scope({ policy = FibersPolicy.nursery({ allow_outward_move = false }) }, function(inner)
      fibers.perform(inner:admit_op(h))
      local ok, err = pcall(function()
        inner:move_op(h, root)
      end)
      denied = not ok and tostring(err):match('denied') ~= nil
    end)
  end)
  assert_truthy(denied, 'strict policy should deny outward custody movement')
end

-- Once fail-fast closure commits, a caught cancellation cannot admit a late child.
do
  local late_started = false
  local late_result
  local r = fibers.try_run(function(scope)
    local never = FibersSignal.new('late-admission-never')
    fibers.spawn(function()
      error('close before late admission', 0)
    end, 'closing-child')
    local ok, err = fibers.pcall(function()
      fibers.perform(never:wait_op())
    end)
    assert_truthy(not ok and FibersRuntime.is_cancelled(err), 'body should observe fail-fast cancellation')
    fibers.mask(function()
      late_result = fibers.perform(scope
        :spawn_op(function()
          late_started = true
        end, 'too-late')
        :map(function()
          return 'admitted'
        end)
        :or_else(fibers.always('rejected')))
    end)
  end)
  assert_eq(r.ok, false)
  assert_eq(r.reason, 'child_failed')
  assert_eq(late_result, 'rejected', 'sealed scope must reject late admission')
  assert_truthy(not late_started, 'a rejected late child must never start')
end

-- Supervisors retain every independently failing child, not only the first.
do
  local r = fibers.try_run(function()
    return fibers.try_scope({ policy = FibersPolicy.supervisor({ child_failure = 'collect' }) }, function()
      fibers.spawn(function()
        error('first collected failure', 0)
      end, 'first-collected')
      fibers.spawn(function()
        error('second collected failure', 0)
      end, 'second-collected')
      return 'done'
    end)
  end)
  assert_truthy(r.ok)
  local inner = r.values[1]
  assert_truthy(inner.ok)
  assert_eq(#inner.report.child_failures, 2, 'all child failures should be retained')
  assert_eq(#inner.report.child_exits, 2, 'all child exits should be retained')
end

print('tests/test_structured_policy.lua: ok')

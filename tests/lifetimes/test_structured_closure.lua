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
local Op = require('fibers.op')
local FibersRuntime = require('fibers.runtime')
local FibersRendezvous = require('fibers.resource.rendezvous')
local FibersSignal = require('fibers.resource.signal')
local Lifetime = require('fibers.lifetime')
local FibersClosure = require('fibers.closure')

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
    local never = FibersSignal.new():label('structured-never')
    sibling = fibers.spawn(function()
      fibers.perform(never:wait_op())
    end):label('blocked-sibling')
    fibers.spawn(function()
      error('live child boom', 0)
    end):label('failing-child')
    local ok, err = fibers.pcall(function()
      fibers.perform(never:wait_op())
    end)
    body_cancelled = not ok and FibersRuntime.is_cancelled(err)
  end)
  assert_eq(r.ok, false)
  assert_eq(r.reason, 'child_failed')
  assert_truthy(body_cancelled, 'nursery should interrupt a blocked body promptly')
  assert_truthy(r.report and #r.report.child_failures == 1, 'child failure should be retained')

  local exit
  fibers.run(function()
    exit = fibers.perform(sibling:body_result_op())
  end)
  assert_eq(exit.tag, 'cancelled', 'sibling should be cancelled by nursery failure')
end

-- Supervisor failure does not interrupt the body or cancel successful siblings.
do
  local body_completed = false
  local sibling_completed = false
  local r = fibers.try_run(function()
    return fibers.try_scope(
      { closure = FibersClosure.supervisor({ child_failure = 'fail_at_exit' }) },
      function()
        local ready = FibersRendezvous.new():label('supervisor-ready')
        fibers.spawn(function()
          error('supervised boom', 0)
        end):label('supervised-failure')
        fibers.spawn(function()
          sibling_completed = true
          fibers.perform(ready:put_op(true))
        end):label('supervised-sibling')
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
    return fibers.try_scope({ closure = FibersClosure.supervisor({ child_failure = 'collect' }) }, function()
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

-- Cancellation of a child scope propagates through its Closure propagation to grandchildren.
do
  local child, grandchild
  local r = fibers.try_run(function()
    local never = FibersSignal.new():label('nested-cancel-never')
    child = fibers.spawn(function()
      grandchild = fibers.spawn(function()
        fibers.perform(never:wait_op())
      end):label('grandchild')
      fibers.perform(never:wait_op())
    end):label('child-with-grandchild')
    fibers.spawn(function()
      error('parent failure', 0)
    end):label('parent-failure')
  end)
  assert_eq(r.ok, false)
  assert_eq(r.reason, 'child_failed')

  local child_exit, grandchild_exit
  fibers.run(function()
    child_exit = fibers.perform(child:body_result_op())
    grandchild_exit = fibers.perform(grandchild:body_result_op())
  end)
  assert_eq(child_exit.tag, 'cancelled')
  assert_eq(grandchild_exit.tag, 'cancelled')
end

-- A strict Closure rule can prohibit custody escape.
do
  local denied = false
  fibers.run(function(root)
    local h = { name = 'strict-move' }
    Lifetime.inert(h)
    fibers.scope({ closure = FibersClosure.nursery({ permit_outward_move = false }) }, function(inner)
      fibers.perform(inner:admit_op(h))
      local ok, err = pcall(function() fibers.perform(inner:move_op(h, root)) end)
      denied = not ok and tostring(err):match('denied') ~= nil
    end)
  end)
  assert_truthy(denied, 'strict Closure should deny outward custody movement')
end

-- Once fail-fast closure commits, a caught cancellation cannot admit a late child.
do
  local late_started = false
  local late_result
  local r = fibers.try_run(function(scope)
    local never = FibersSignal.new():label('late-admission-never')
    fibers.spawn(function()
      error('close before late admission', 0)
    end):label('closing-child')
    local ok, err = fibers.pcall(function()
      fibers.perform(never:wait_op())
    end)
    assert_truthy(not ok and FibersRuntime.is_cancelled(err), 'body should observe fail-fast cancellation')
    fibers.mask(function()
      late_result = fibers.perform(scope
        :spawn_op(function()
          late_started = true
        end, { label = 'too-late' })
        :map(function()
          return 'admitted'
        end)
        :or_else(Op.always('rejected')))
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
    return fibers.try_scope({ closure = FibersClosure.supervisor({ child_failure = 'collect' }) }, function()
      fibers.spawn(function()
        error('first collected failure', 0)
      end):label('first-collected')
      fibers.spawn(function()
        error('second collected failure', 0)
      end):label('second-collected')
      return 'done'
    end)
  end)
  assert_truthy(r.ok)
  local inner = r.values[1]
  assert_truthy(inner.ok)
  assert_eq(#inner.report.child_failures, 2, 'all child failures should be retained')
  assert_eq(#inner.report.child_exits, 2, 'all child exits should be retained')
end

print('tests/test_structured_closure.lua: ok')

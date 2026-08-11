-- Regression tests for speculative phase integrity across admission, spawning and
-- cancellation. Losing or unresolved worlds must not mutate retained objects;
-- committed effects may move ownership only after managed-state commit.

package.path = table.concat({
  './src/?.lua', './src/?/init.lua', './src/?/?.lua',
  './?.lua', './?/init.lua', './?/?.lua', package.path,
}, ';')

local Op = require('fibers.op')
local Effect = require('fibers.effect')
local Runtime = require('fibers.runtime')
local Scope = require('fibers.scope')
local Lifetime = require('fibers.lifetime')
local Closure = require('fibers.closure')
local LifetimeState = require('tests.support.lifetimes')

local function eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assertion failed') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual), 2)
  end
end

local function truthy(value, message)
  if not value then error(message or 'expected truthy value', 2) end
end

local function run_to_rest(runtime)
  local status
  repeat status = runtime:run() until status.tag ~= 'found'
  return status
end

-- Constructing or defeating admission does not affiliate a dormant Lifetime.
do
  local first_runtime = Runtime.new({ quiet_deadlock = true })
  local first_scope = Scope.new():label('phase-admission-first')
  local value = { name = 'phase-admission-value' }
  Lifetime.define(value, { label = value.name })
  local node = value._lifetime
  local fallback

  first_runtime:spawn_raw(function()
    local admission = first_scope:admit_op(value)
    eq(node._runtime, nil, 'admission construction must remain runtime-neutral')
    fallback = first_runtime:perform(admission
      :and_then(Op.never())
      :or_else(Op.always('fallback')))
    eq(node._runtime, nil, 'defeated admission must not bind a runtime')
    eq(node._lifetime_location.value.phase, 'dormant', 'defeated admission must remain dormant')
  end):label('phase-admission-first-driver')

  local first_status = run_to_rest(first_runtime)
  eq(fallback, 'fallback')
  truthy(first_status.tag == 'quiescent' or first_status.tag == 'idle')

  local second_runtime = Runtime.new()
  local second_scope = Scope.new():label('phase-admission-second')
  local late_child = { name = 'phase-admission-late-child' }
  Lifetime.define(late_child, { label = late_child.name })
  second_runtime:spawn_raw(function()
    local admission = second_scope:admit_op(value)
    node:add_child(late_child)
    eq(late_child._lifetime._runtime, nil,
      'a child added after construction remains unaffiliated before commit')
    eq(second_runtime:perform(admission), value)
    eq(node._runtime, second_runtime, 'committed admission binds the selected runtime')
    eq(second_scope:_store():_phase(node), 'live', 'committed admission makes the Lifetime live')
    eq(late_child._lifetime._runtime, second_runtime,
      'admission reads the current dormant graph at performance')
    eq(second_scope:_store():_phase(late_child._lifetime), 'live', 'late dormant child is admitted atomically')
    second_scope:close(value, 'phase-admission-done')
  end):label('phase-admission-second-driver')
  local second_status = run_to_rest(second_runtime)
  truthy(second_status.tag == 'quiescent' or second_status.tag == 'idle')
end

-- A spawn option may be explored, defeated and then reused. Its body is moved
-- into a runnable frame only by committed effect discharge.
do
  local runtime = Runtime.new()
  local scope = Scope.new():label('phase-spawn-scope')
  local starts = 0
  local fallback, task, returned

  runtime:spawn_raw(function()
    local spawn = scope:spawn_op(function()
      starts = starts + 1
      return 'spawned'
    end, { label = 'phase-spawn-task' })

    fallback = runtime:perform(spawn
      :and_then(Op.never())
      :or_else(Op.always('fallback')))
    eq(starts, 0, 'defeated spawn must not start or consume its body')

    task = runtime:perform(spawn)
    returned = runtime:perform(task:await_op())
    eq(starts, 1, 'committed spawn starts exactly once')
    scope:close(task, 'phase-spawn-done')
  end):label('phase-spawn-driver')

  local status = run_to_rest(runtime)
  eq(fallback, 'fallback')
  eq(returned, 'spawned')
  truthy(task ~= nil)
  truthy(status.tag == 'quiescent' or status.tag == 'idle')
end

-- Admission itself now owns activation; there is no separate owned-spawn
-- Effect path to test here.

-- A losing cancellation option leaves both managed cancellation and ordinary
-- closure bookkeeping untouched. The bookkeeping is updated only after commit.
do
  local runtime = Runtime.new()
  local scope = Scope.new():label('phase-cancel-scope')
  local fallback, committed

  runtime:spawn_raw(function()
    local cancel_option = scope:request_cancel_op('lost-cancellation')
    eq(((LifetimeState.state(scope).close_request or {}).reason), nil,
      'constructing cancellation must not commit a Lifetime close reason')
    eq(LifetimeState.closure_state(scope), nil,
      'constructing cancellation must not allocate supervision state')
    local losing = cancel_option
      :and_then(Op.never())
      :or_else(Op.always('fallback'))
    fallback = runtime:perform(losing)
    eq(((LifetimeState.state(scope).close_request or {}).reason), nil,
      'defeated cancellation must not commit a Lifetime close reason')
    eq(LifetimeState.interrupt(scope).raised, false, 'defeated cancellation must not raise the interrupt')

    committed = runtime:perform(scope:request_cancel_op('committed-cancellation'))
    eq(((LifetimeState.state(scope).close_request or {}).reason), 'committed-cancellation',
      'committed cancellation records the Lifetime close reason post-commit')
  end):label('phase-cancel-driver')

  local status = run_to_rest(runtime)
  eq(fallback, 'fallback')
  eq(committed, true)
  truthy(status.tag == 'quiescent' or status.tag == 'idle')
end

-- Child-outcome propagation preserves the original cancellation reason and
-- interrupt token rather than nesting the Runtime cancellation object as reason.
do
  local runtime = Runtime.new()
  local parent = Scope.new():label('phase-cancel-parent')
  local task, body_exit, child_exit
  local reason = { kind = 'phase-cancellation-reason' }

  runtime:spawn_raw(function()
    task = runtime:perform(parent:spawn_op(function(child)
      child:perform(Op.never())
    end, { label = 'phase-cancel-child' }))
    runtime:perform(task:request_cancel_op(reason))
    body_exit = runtime:perform(task:body_result_op())
    runtime:perform(task:outcome_op())
    local entry = LifetimeState.closure_state(parent).processed[task:lifetime()]
    child_exit = entry and entry.exit or nil
    parent:close(task, 'phase-cancel-child-retired')
  end):label('phase-cancel-parent-driver')

  local status = run_to_rest(runtime)
  eq(body_exit.tag, 'cancelled')
  eq(body_exit.reason, reason)
  eq(body_exit.token, LifetimeState.interrupt(task))
  truthy(child_exit ~= nil, 'parent receives the child outcome')
  eq(child_exit.tag, 'cancelled')
  eq(child_exit.reason, reason, 'propagated Exit keeps the raw cancellation reason')
  eq(child_exit.token, LifetimeState.interrupt(task), 'propagated Exit keeps the interrupt token')
  truthy(status.tag == 'quiescent' or status.tag == 'idle')
end

print('tests/lifetimes/test_phase_integrity.lua: ok')

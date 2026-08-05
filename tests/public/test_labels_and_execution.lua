-- Labels are semantically inert diagnostic metadata, and execution contracts
-- may assert that a dynamic region does not relinquish the current fiber turn.

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
local Runtime = require('fibers.runtime')
local Channel = require('fibers.channel')
local Cell = require('fibers.resource.cell')
local Operation = require('fibers.internal.operation')
local Lifetime = require('fibers.lifetime')

local function pack(...)
  return { n = select('#', ...), ... }
end

local function test_option_labels_are_immutable_annotations()
  local base = Op.always('value')
  local inner = base:label('inner')
  local outer = inner:label('outer')

  assert(base ~= inner)
  assert(inner ~= outer)
  assert(Operation.diagnostic_label(base) == nil)
  assert(Operation.diagnostic_label(inner) == 'inner')
  assert(Operation.diagnostic_label(outer) == 'outer')
  assert(#Operation.labels(outer) == 2)
  assert(Operation.labels(outer)[1] == 'outer')
  assert(Operation.labels(outer)[2] == 'inner')

  local got
  local rt = Runtime.new()
  rt:spawn_raw(function()
    got = rt:perform(outer)
  end)
  assert(rt:run().tag == 'found')
  assert(got == 'value')
end

local function test_identity_labels_are_fluent_and_non_semantic()
  local embedded = Runtime.new():label('embedded-runtime')
  assert(embedded:label() == 'embedded-runtime')

  local channel = Channel.new(2):label('service-commands')
  local state = Cell.new('idle'):label('service-state')

  assert(channel:label() == 'service-commands')
  assert(state:label() == 'service-state')

  channel:label('renamed-commands')
  assert(channel:label() == 'renamed-commands')
  channel:label(nil)
  assert(channel:label() == nil)

  local retained = Lifetime.inert({ name = 'retained-resource' }, {
    label = 'initial-resource-label',
  })
  assert(retained:label() == 'initial-resource-label')
  retained:label('updated-resource-label')
  assert(Lifetime.of(retained):label() == 'updated-resource-label')

  fibers.run(function(scope)
    assert(scope:label('root-scope') == scope)
    assert(scope:label() == 'root-scope')
    assert(scope:lifetime():label() == 'root-scope')
    local report = scope:_make_report(nil, {}, {})
    assert(report.scope_name == 'root-scope')

    local task = scope:spawn(function()
      return state:read()
    end):label('state-reader')

    assert(task:label() == 'state-reader')
    assert(task:lifetime():label() == 'state-reader')
    assert(task:await() == 'idle')
  end)
end

local function test_without_suspension_allows_immediate_performs()
  local state = Cell.new(7):label('state')

  fibers.run(function()
    local result = pack(fibers.without_suspension(function()
      assert(fibers.perform(Op.always(true):label('immediate')) == true)
      assert(fibers.perform(Op.never():or_else(Op.always('fallback'))) == 'fallback')
      assert(state:read() == 7)

      return fibers.without_suspension(function()
        return 'a', nil, 'c'
      end)
    end))

    assert(result.n == 3)
    assert(result[1] == 'a')
    assert(result[2] == nil)
    assert(result[3] == 'c')
  end)
end

local function test_without_suspension_fails_before_parking()
  local blocked = Channel.new():label('blocked-channel')
  local caught

  fibers.run(function()
    local ok, err = fibers.pcall(function()
      fibers.without_suspension(function()
        return fibers.perform(blocked:get_op():label('await-blocked-value'))
      end)
    end)

    assert(ok == false)
    assert(type(err) == 'table')
    assert(err.kind == 'suspension_error')
    assert(err.operation_label == 'await-blocked-value')
    assert(err.region and err.region.kind == 'without_suspension')
    assert(type(err.message) == 'string' and err.message:find('await%-blocked%-value'))
    caught = true

    -- The dynamic contract is restored on failure; ordinary suspension remains
    -- available after the asserted region has unwound.
    fibers.spawn(function()
      blocked:put('ok')
    end)
    assert(blocked:get() == 'ok')
  end)

  assert(caught == true)
end

local function test_task_label_reaches_suspension_diagnostics()
  local blocked = Channel.new():label('task-blocked-channel')

  fibers.run(function(scope)
    local task = scope:spawn(function()
      local ok, err = fibers.pcall(function()
        fibers.without_suspension(function()
          fibers.perform(blocked:get_op():label('task-blocked-get'))
        end)
      end)
      assert(ok == false)
      assert(err.kind == 'suspension_error')
      assert(err.fiber_label == 'strict-worker')
      assert(err.operation_label == 'task-blocked-get')
    end):label('strict-worker')

    task:await()
  end)
end

local function test_without_suspension_respects_runtime_budgets()
  local rt = Runtime.new({ cycle_work_limit = 1, quiet_deadlock = true })
  local caught

  rt:spawn_raw(function()
    local ok, err = fibers.pcall(function()
      return fibers.without_suspension(function()
        return fibers.perform(
          Op.never():or_else(Op.always('fallback'))
            :label('budgeted-fallback')
        )
      end)
    end)
    assert(ok == false)
    assert(err.kind == 'suspension_error')
    assert(err.operation_label == 'budgeted-fallback')
    assert(err.reason == 'cycle_work_limit')
    caught = true
  end):label('budgeted-strict-region')

  assert(rt:run().tag == 'idle')
  assert(caught == true)
end

local function test_without_suspension_does_not_run_an_older_participant()
  local rt = Runtime.new({ quiet_deadlock = true })
  local rendezvous = Channel.new():label('handoff')
  local order = {}

  rt:spawn_raw(function()
    rendezvous:get()
    order[#order + 1] = 'receiver'
  end):label('receiver')
  local pending = rt:run()
  assert(pending.tag == 'quiescent' or pending.tag == 'pending')

  rt:spawn_raw(function()
    local ok, err = fibers.pcall(function()
      fibers.without_suspension(function()
        fibers.perform(rendezvous:put_op('value'):label('handoff-value'))
      end)
    end)
    assert(ok == false)
    assert(err.kind == 'suspension_error')
    order[#order + 1] = 'caught'
  end):label('strict-sender')

  rt:run()
  assert(#order == 1 and order[1] == 'caught')

  rt:spawn_raw(function()
    rendezvous:put('value')
  end):label('ordinary-sender')
  rt:run()
  assert(order[2] == 'receiver')
end

test_option_labels_are_immutable_annotations()
test_identity_labels_are_fluent_and_non_semantic()
test_without_suspension_allows_immediate_performs()
test_without_suspension_fails_before_parking()
test_task_label_reaches_suspension_diagnostics()
test_without_suspension_respects_runtime_budgets()
test_without_suspension_does_not_run_an_older_participant()

print('labels and execution contracts: ok')

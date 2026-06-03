package.path = './?.lua;../?.lua;./?/init.lua;../?/init.lua;' .. package.path

local core = require('etfcore')
local Op = core.Op
local Runtime = require('runtime').Runtime
local JudgementContext = core.JudgementContext
local ProofSearch = core.ProofSearch
local PostProgram = core.PostProgram
local Channel = require('resources.channel')
local Ledger = require('ledger')

local EvidenceDelta = core._test.EvidenceDelta
local OccurrenceRef = core._test.OccurrenceRef
local SettlementRef = core._test.SettlementRef
local pack = core._test.pack
local expand_expr = core._test.expand_expr
local expand_top_frame = core._test.expand_top_frame
local ExpansionContext = core._test.ExpansionContext
local PartialProof = core._test.PartialProof
local forced_decisions_for_obligation = core._test.forced_decisions_for_obligation
local committable_search_key = core._test.committable_search_key
local WorldEvidence = core._test.WorldEvidence
local ResumptionEvidence = core._test.ResumptionEvidence
local RootAttempt = core._test.RootAttempt
local CommitPlan = core._test.CommitPlan

local function assert_eq(a, b, message)
  if a ~= b then error((message or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2) end
end


local function test_derivation_addresses_are_stable()
  local ch = Channel.new('addr-stable')
  local operation = Op.tensor({ ch:put_op('x'), ch:get_op() })

  local frames1 = expand_expr(operation, EvidenceDelta.empty(), ExpansionContext.root('addr-root'))
  local frames2 = expand_expr(operation, EvidenceDelta.empty(), ExpansionContext.root('addr-root'))

  assert_eq(frames1[1].lanes[1].addr, frames2[1].lanes[1].addr, 'lane 1 address should be replay-stable')
  assert_eq(frames1[1].lanes[2].addr, frames2[1].lanes[2].addr, 'lane 2 address should be replay-stable')
  assert(frames1[1].lanes[1].addr ~= frames1[1].lanes[2].addr, 'distinct tensor lanes should have distinct addresses')
  assert(frames1[1].box.addr and frames1[1].box.addr:match('addr%-root'), 'box should carry derivation address')
  assert(frames1[1].lanes[1].port.box == frames1[1].box, 'lane 1 port should be physically inside product box')
  assert(frames1[1].lanes[2].port.box == frames1[1].box, 'lane 2 port should be physically inside product box')
end

local function drain_runnable(rt)
  while #rt.runnable > 0 do
    local task = table.remove(rt.runnable, 1)
    rt:resume_task(task)
  end
end

local function first_proof_for(task)
  local frame = assert(task.frontier and task.frontier[1], 'task has no frontier')
  local used = { [task] = true }
  return PartialProof.new(expand_top_frame(task, frame), used, {})
end


local function test_bind_link_is_explicit_and_reduced_by_search()
  local called = false
  local op = Op.always('x'):and_then(function(x)
    called = true
    return Op.always(x .. '!')
  end)

  local frames = expand_expr(op, EvidenceDelta.empty(), ExpansionContext.root('explicit-bind-link'))
  assert_eq(called, false, 'bind callback should not run during ordinary expansion')
  assert_eq(frames[1].kind, 'bind', 'bind should produce an explicit BindFrame')
  assert_eq(frames[1].source.kind, 'done', 'BindFrame source should be a done frame')
  assert(frames[1].link, 'BindFrame should carry an explicit BindLink')
  assert_eq(frames[1].link.kind, 'bind', 'expected explicit BindLink')

  local rt = Runtime.new()
  local got
  rt:spawn(function()
    got = Op.perform(op)
  end, 'explicit-bind-link-root')

  drain_runnable(rt)
  assert_eq(called, false, 'bind callback should not run while parking the root')
  rt:run()
  assert_eq(called, true, 'bind callback should run during proof-search link reduction')
  assert_eq(got, 'x!', 'BindLink should feed returned Op into the same transaction')
end

local function test_map_link_is_explicit_and_reduced_by_search()
  local called = false
  local op = Op.always('x'):map(function(x)
    called = true
    return x .. '?'
  end)

  local frames = expand_expr(op, EvidenceDelta.empty(), ExpansionContext.root('explicit-map-link'))
  assert_eq(called, false, 'map callback should not run during ordinary expansion')
  assert_eq(frames[1].kind, 'map', 'map should produce an explicit MapFrame')
  assert_eq(frames[1].source.kind, 'done', 'MapFrame source should be a done frame')
  assert(frames[1].link, 'MapFrame should carry an explicit MapLink')
  assert_eq(frames[1].link.kind, 'map', 'expected explicit MapLink')

  local rt = Runtime.new()
  local got
  rt:spawn(function()
    got = Op.perform(op)
  end, 'explicit-map-link-root')

  drain_runnable(rt)
  assert_eq(called, false, 'map callback should not run while parking the root')
  rt:run()
  assert_eq(called, true, 'map callback should run during proof-search link reduction')
  assert_eq(got, 'x?', 'MapLink should transform the raw value before commit')
end

local function test_map_is_transactional_before_commit_and_wrap_after_commit()
  local rt = Runtime.new()
  local order = {}
  local got

  local old_print_event = core.print_event
  core.print_event = function(event)
    if event.tag == 'map-order.event' then
      order[#order + 1] = 'commit'
    else
      old_print_event(event)
    end
  end

  rt:spawn(function()
    got = Op.perform(
      Op.always('x')
        :map(function(x)
          order[#order + 1] = 'map'
          return x .. 'm'
        end)
        :and_then(function(x)
          return Op.emit({ tag = 'map-order.event' }):and_then(function()
            return Op.always(x)
          end)
        end)
        :wrap(function(x)
          order[#order + 1] = 'wrap'
          return x .. 'w'
        end)
    )
  end, 'map-order-root')

  rt:run()
  core.print_event = old_print_event

  assert_eq(got, 'xmw', 'map should affect raw value and wrap should affect returned value')
  assert_eq(order[1], 'map', 'map should run during proof search before commit events')
  assert_eq(order[2], 'commit', 'commit event should run after map')
  assert_eq(order[3], 'wrap', 'wrap should run after commit')
end

local function test_map_callback_cannot_perform()
  local rt = Runtime.new()
  local ch = Channel.new('bad-map-perform')
  rt.quiet_deadlock = true

  rt:spawn(function()
    Op.perform(Op.always('x'):map(function()
      return Op.perform(ch:get_op())
    end))
  end, 'bad-map-perform-root')

  drain_runnable(rt)
  local ok, err = pcall(function() rt:try_commit_one() end)
  assert(ok == false, 'perform during MapLink reduction should fail')
  assert(tostring(err):match('proof search'), 'expected proof search error, got ' .. tostring(err))
end

local function test_bind_callback_must_return_op()
  local rt = Runtime.new()

  rt:spawn(function()
    Op.perform(Op.always('x'):and_then(function()
      return 'not-an-op'
    end))
  end, 'bad-bind-return-root')

  drain_runnable(rt)
  local ok, err = pcall(function() rt:try_commit_one() end)
  assert(ok == false, 'bind callback returning non-Op should fail')
  assert(tostring(err):match('callback must return an Op'), 'expected callback return error, got ' .. tostring(err))
end


local function test_guard_does_not_run_at_construction_and_runs_at_expansion()
  local called = 0
  local op = Op.guard(function()
    called = called + 1
    return Op.always('guarded')
  end)

  assert_eq(called, 0, 'guard callback should not run at construction')

  local frames = expand_expr(op, EvidenceDelta.empty(), ExpansionContext.root('guard-expansion'))
  assert_eq(called, 1, 'guard callback should run during proof expansion')
  assert_eq(#frames, 1, 'guard returning always should produce one frame')
  assert_eq(frames[1].kind, 'done', 'guarded always should close')
  assert_eq(frames[1].values[1], 'guarded', 'guard result value should come from returned Op')
end

local function test_guard_is_memoized_per_attempt_occurrence()
  local called = 0
  local op = Op.guard(function()
    called = called + 1
    return Op.always('value-' .. tostring(called))
  end)

  local task = { id = 101, parked = true }
  local attempt = RootAttempt.new(task, op, 1, 1)
  task.attempt = attempt
  task.attempt_id = attempt.id

  local ctx = ExpansionContext.root('guard-memo-root', task, nil, attempt)
  local frames1 = expand_expr(op, EvidenceDelta.empty(), ctx)
  local frames2 = expand_expr(op, EvidenceDelta.empty(), ctx)

  assert_eq(called, 1, 'guard should be memoized for the same attempt occurrence')
  assert_eq(frames1[1].values[1], 'value-1', 'first expansion should use first guarded Op')
  assert_eq(frames2[1].values[1], 'value-1', 'replay should reuse memoized guarded Op')

  local attempt2 = RootAttempt.new(task, op, 2, 2)
  task.attempt = attempt2
  task.attempt_id = attempt2.id
  local frames3 = expand_expr(op, EvidenceDelta.empty(), ExpansionContext.root('guard-memo-root', task, nil, attempt2))

  assert_eq(called, 2, 'guard should run again for a new attempt')
  assert_eq(frames3[1].values[1], 'value-2', 'new attempt should receive new guarded Op')
end

local function test_guard_callback_must_return_op()
  local ok, err = pcall(function()
    expand_expr(Op.guard(function()
      return 'not-an-op'
    end), EvidenceDelta.empty(), ExpansionContext.root('bad-guard-return'))
  end)

  assert(ok == false, 'guard callback returning non-Op should fail')
  assert(tostring(err):match('callback must return an Op'), 'expected guard callback return error, got ' .. tostring(err))
end

local function test_guard_callback_cannot_perform_or_spawn()
  local rt = Runtime.new()
  rt.quiet_deadlock = true
  local ch = Channel.new('bad-guard-perform')

  rt:spawn(function()
    Op.perform(Op.guard(function()
      return Op.perform(ch:get_op())
    end))
  end, 'bad-guard-perform-root')

  local ok, err = pcall(function() drain_runnable(rt) end)
  assert(ok == false, 'perform during guard expansion should fail')
  assert(tostring(err):match('proof search'), 'expected proof search error, got ' .. tostring(err))

  rt = Runtime.new()
  rt:spawn(function()
    Op.perform(Op.guard(function()
      rt:spawn(function() end, 'bad-spawned-during-guard')
      return Op.always('ok')
    end))
  end, 'bad-guard-spawn-root')

  ok, err = pcall(function() drain_runnable(rt) end)
  assert(ok == false, 'spawn during guard expansion should fail')
  assert(tostring(err):match('proof search'), 'expected proof search error, got ' .. tostring(err))
end

local function test_or_else_function_fallback_is_guarded_and_memoized()
  local called = 0
  local op = Op.never():or_else(function()
    called = called + 1
    return Op.always('fallback-' .. tostring(called))
  end)

  local task = { id = 102, parked = true }
  local attempt = RootAttempt.new(task, op, 1, 1)
  task.attempt = attempt
  task.attempt_id = attempt.id
  local ctx = ExpansionContext.root('guarded-fallback-root', task, nil, attempt)

  local frames1 = expand_expr(op, EvidenceDelta.empty(), ctx)
  local frames2 = expand_expr(op, EvidenceDelta.empty(), ctx)

  assert_eq(called, 1, 'function fallback should be memoized through Op.guard')
  assert_eq(#frames1, 1, 'fallback should produce one frame')
  assert_eq(#frames2, 1, 'replayed fallback should produce one frame')
  assert_eq(frames1[1].values[1], 'fallback-1', 'fallback should use first guarded value')
  assert_eq(frames2[1].values[1], 'fallback-1', 'fallback replay should reuse guarded value')
end


local function first_settlement_cell(rt)
  for _, cell in pairs(rt.settlements or {}) do
    return cell
  end
  return nil
end

local function count_settlements(rt)
  local n = 0
  for _ in pairs(rt.settlements or {}) do n = n + 1 end
  return n
end

local function test_with_nack_callback_timing_and_return_contract()
  local called = 0
  local op = Op.with_nack(function(nack)
    called = called + 1
    assert_eq(nack.tag, 'nack', 'callback should receive a nack Op')
    return Op.always('protected')
  end)

  assert_eq(called, 0, 'with_nack callback should not run at construction')
  local frames = expand_expr(op, EvidenceDelta.empty(), ExpansionContext.root('with-nack-expansion'))
  assert_eq(called, 1, 'with_nack callback should run during proof expansion')
  assert_eq(#frames, 1, 'protected always should produce one frame')
  assert_eq(frames[1].kind, 'done', 'protected always should close')

  local ok, err = pcall(function()
    expand_expr(Op.with_nack(function()
      return 'not-an-op'
    end), EvidenceDelta.empty(), ExpansionContext.root('bad-with-nack-return'))
  end)
  assert(ok == false, 'with_nack callback returning non-Op should fail')
  assert(tostring(err):match('callback must return an Op'), 'expected callback return error, got ' .. tostring(err))
end

local function test_with_nack_is_memoized_per_attempt_occurrence()
  local called = 0
  local saved_ref
  local op = Op.with_nack(function(nack)
    called = called + 1
    saved_ref = nack.settlement
    return Op.always('value-' .. tostring(called))
  end)

  local task = { id = 301, parked = true }
  local attempt = RootAttempt.new(task, op, 1, 1)
  task.attempt = attempt
  task.attempt_id = attempt.id

  local ctx = ExpansionContext.root('with-nack-memo-root', task, nil, attempt)
  local frames1 = expand_expr(op, EvidenceDelta.empty(), ctx)
  local ref1 = saved_ref
  local frames2 = expand_expr(op, EvidenceDelta.empty(), ctx)
  local ref2 = saved_ref

  assert_eq(called, 1, 'with_nack should memoize callback for the same attempt occurrence')
  assert_eq(ref1, ref2, 'with_nack replay should reuse the same SettlementRef')
  assert_eq(frames1[1].values[1], 'value-1', 'first protected op should use first value')
  assert_eq(frames2[1].values[1], 'value-1', 'replay should reuse protected op')

  local attempt2 = RootAttempt.new(task, op, 2, 2)
  task.attempt = attempt2
  task.attempt_id = attempt2.id
  local frames3 = expand_expr(op, EvidenceDelta.empty(), ExpansionContext.root('with-nack-memo-root', task, nil, attempt2))
  assert_eq(called, 2, 'with_nack should run again for a new attempt')
  assert_eq(frames3[1].values[1], 'value-2', 'new attempt should receive new protected op')
end

local function test_with_nack_selected_and_nack_never_closes()
  local rt = Runtime.new()
  rt.quiet_deadlock = true
  local saved_nack
  local got

  rt:spawn(function()
    got = Op.perform(Op.with_nack(function(nack)
      saved_nack = nack
      return Op.always('ok')
    end))
  end, 'with-nack-selected-root')

  rt:run()
  assert_eq(got, 'ok', 'protected occurrence should commit')
  local cell = assert(first_settlement_cell(rt), 'selected with_nack should create a settlement cell')
  assert_eq(cell.state, 'selected', 'committed protected occurrence should settle selected')
  assert_eq(cell.published, true, 'retained live frontier occurrence should be published')

  local nack_done = false
  rt:spawn(function()
    Op.perform(saved_nack)
    nack_done = true
  end, 'selected-nack-root')
  local ok = pcall(function() rt:run() end)
  assert(ok == false, 'nack should not close after selected settlement')
  assert_eq(nack_done, false, 'selected nack should not resume')
end

local function test_with_nack_published_alternative_loses_and_nack_closes_later()
  local rt = Runtime.new()
  rt.quiet_deadlock = true
  local ch = Channel.new('with-nack-lost')
  local saved_nack
  local got

  rt:spawn(function()
    got = Op.perform(Op.choice(
      Op.with_nack(function(nack)
        saved_nack = nack
        return ch:get_op()
      end),
      Op.always('fallback')
    ))
  end, 'with-nack-lost-root')

  rt:run()
  assert_eq(got, 'fallback', 'fallback should commit while protected wait is excluded')
  local cell = assert(rt:settlement_cell(saved_nack.settlement), 'lost with_nack should have a settlement cell')
  assert_eq(cell.published, true, 'protected wait in retained frontier should be published')
  assert_eq(cell.state, 'lost', 'published protected occurrence excluded by same resolved root should settle lost')

  local nack_done = false
  rt:spawn(function()
    Op.perform(saved_nack)
    nack_done = true
  end, 'lost-nack-root')
  rt:run()
  assert_eq(nack_done, true, 'nack should close after prior lost settlement')
end

local function test_with_nack_same_world_circularity_does_not_close()
  local rt = Runtime.new()
  rt.quiet_deadlock = true
  local committed = false

  rt:spawn(function()
    Op.perform(Op.with_nack(function(nack)
      return Op.never():or_else(nack)
    end))
    committed = true
  end, 'with-nack-circular-root')

  local ok = pcall(function() rt:run() end)
  assert(ok == false, 'nack must not observe loss from the same CommitPlan')
  assert_eq(committed, false, 'circular nack branch should not commit')
end

local function test_with_nack_unrelated_commit_does_not_fire_pending_nack()
  local rt = Runtime.new()
  rt.quiet_deadlock = true
  local ch_pending = Channel.new('with-nack-pending')
  local ch_other = Channel.new('with-nack-other')
  local saved_nack

  rt:spawn(function()
    Op.perform(Op.with_nack(function(nack)
      saved_nack = nack
      return ch_pending:get_op()
    end))
  end, 'pending-with-nack-root')

  rt:spawn(function()
    Op.perform(ch_other:put_op('x'))
  end, 'other-sender')

  local other_got
  rt:spawn(function()
    other_got = Op.perform(ch_other:get_op())
  end, 'other-receiver')

  drain_runnable(rt)
  assert(saved_nack, 'pending with_nack should have been expanded while parking')
  local status = rt:try_commit_one()
  assert_eq(status, 'committed', 'unrelated rendezvous should commit')
  assert_eq(other_got, nil, 'receiver resumes after runnable drain')
  drain_runnable(rt)
  assert_eq(other_got, 'x', 'unrelated receiver should receive value')

  local cell = rt:settlement_cell(saved_nack.settlement)
  assert_eq(cell.state, 'pending', 'unrelated commit must not settle pending with_nack')
  assert_eq(cell.published, true, 'pending protected occurrence should remain published')
end

local function test_with_nack_bind_created_occurrence_selects_without_publication()
  local rt = Runtime.new()
  rt.quiet_deadlock = true
  local saved_nack
  local got

  rt:spawn(function()
    got = Op.perform(Op.always('x'):and_then(function(x)
      return Op.with_nack(function(nack)
        saved_nack = nack
        return Op.always(x .. '-inner')
      end)
    end))
  end, 'with-nack-bind-root')

  drain_runnable(rt)
  assert_eq(saved_nack, nil, 'bind-created with_nack should not be reached while parking')
  rt:run()
  assert_eq(got, 'x-inner', 'bind-created protected occurrence should commit')
  local cell = rt:settlement_cell(saved_nack.settlement)
  assert_eq(cell.state, 'selected', 'bind-created selected occurrence should settle selected')
  assert_eq(cell.published, false, 'bind-created selected occurrence need not be published first')
end

local function test_with_nack_withdrawal_enables_nack()
  local rt = Runtime.new()
  rt.quiet_deadlock = true
  local ch = Channel.new('with-nack-withdraw')
  local saved_nack

  local task = rt:spawn(function()
    Op.perform(Op.with_nack(function(nack)
      saved_nack = nack
      return ch:get_op()
    end))
  end, 'withdrawn-with-nack-root')

  drain_runnable(rt)
  assert(saved_nack, 'withdrawn with_nack should be expanded while parking')
  local ok, reason = rt:withdraw_attempt(task.attempt, 'test-withdraw')
  assert(ok, reason or 'withdraw should succeed')
  local cell = rt:settlement_cell(saved_nack.settlement)
  assert_eq(cell.state, 'withdrawn', 'withdraw should settle published pending refs as withdrawn')

  local nack_done = false
  rt:spawn(function()
    Op.perform(saved_nack)
    nack_done = true
  end, 'withdrawn-nack-root')
  rt:run()
  assert_eq(nack_done, true, 'nack should close after prior withdrawn settlement')
end


local function test_with_nack_nested_parent_child_settlement()
  local rt = Runtime.new()
  rt.quiet_deadlock = true
  local ch = Channel.new('with-nack-nested')
  local outer_nack, inner_nack
  local got

  rt:spawn(function()
    got = Op.perform(Op.choice(
      Op.with_nack(function(n1)
        outer_nack = n1
        return Op.with_nack(function(n2)
          inner_nack = n2
          return ch:get_op()
        end)
      end),
      Op.always('fallback')
    ))
  end, 'with-nack-nested-root')

  rt:run()
  assert_eq(got, 'fallback', 'nested fallback should commit')
  assert_eq(rt:settlement_cell(outer_nack.settlement).state, 'lost', 'outer published occurrence should be lost')
  assert_eq(rt:settlement_cell(inner_nack.settlement).state, 'withdrawn', 'child under lost parent should be withdrawn')

  local rt2 = Runtime.new()
  rt2.quiet_deadlock = true
  local selected_outer, selected_inner
  local selected_got
  rt2:spawn(function()
    selected_got = Op.perform(Op.with_nack(function(n1)
      selected_outer = n1
      return Op.with_nack(function(n2)
        selected_inner = n2
        return Op.always('selected')
      end)
    end))
  end, 'with-nack-nested-selected-root')
  rt2:run()
  assert_eq(selected_got, 'selected', 'nested protected body should commit')
  assert_eq(rt2:settlement_cell(selected_outer.settlement).state, 'selected', 'outer nested occurrence should be selected')
  assert_eq(rt2:settlement_cell(selected_inner.settlement).state, 'selected', 'inner nested occurrence should be selected')
end


local function test_nack_op_closes_inside_tensor_and_all()
  local rt = Runtime.new()
  rt.quiet_deadlock = true
  local ch = Channel.new('nack-product-lost')
  local saved_nack

  rt:spawn(function()
    Op.perform(Op.choice(
      Op.with_nack(function(nack)
        saved_nack = nack
        return ch:get_op()
      end),
      Op.always('fallback')
    ))
  end, 'nack-product-source')

  rt:run()
  assert(saved_nack, 'source with_nack should expose a nack')
  assert_eq(rt:settlement_cell(saved_nack.settlement).state, 'lost', 'source protected occurrence should be lost')

  local tensor_got
  rt:spawn(function()
    tensor_got = Op.perform(Op.tensor({ saved_nack, Op.always('tensor-side') }))
  end, 'nack-inside-tensor')
  rt:run()

  assert(type(tensor_got) == 'table', 'tensor with nack lane should commit')
  assert_eq(tensor_got[1].n, 0, 'nack tensor lane should return no values')
  assert_eq(tensor_got[2][1], 'tensor-side', 'tensor side lane should return normally')

  local all_got
  rt:spawn(function()
    all_got = Op.perform(Op.all({ saved_nack, Op.always('all-side') }))
  end, 'nack-inside-all')
  rt:run()

  assert(type(all_got) == 'table', 'all with nack lane should commit')
  assert_eq(all_got[1].n, 0, 'nack all lane should return no values')
  assert_eq(all_got[2][1], 'all-side', 'all side lane should return normally')
end

local function test_with_nack_protected_occurrence_selects_inside_tensor_and_all()
  local rt = Runtime.new()
  rt.quiet_deadlock = true
  local tensor_nack, all_nack
  local tensor_got, all_got

  rt:spawn(function()
    tensor_got = Op.perform(Op.tensor({
      Op.with_nack(function(nack)
        tensor_nack = nack
        return Op.always('tensor-protected')
      end),
      Op.always('tensor-side')
    }))
  end, 'with-nack-inside-tensor')

  rt:spawn(function()
    all_got = Op.perform(Op.all({
      Op.with_nack(function(nack)
        all_nack = nack
        return Op.always('all-protected')
      end),
      Op.always('all-side')
    }))
  end, 'with-nack-inside-all')

  rt:run()

  assert_eq(tensor_got[1][1], 'tensor-protected', 'protected tensor lane should return normally')
  assert_eq(tensor_got[2][1], 'tensor-side', 'tensor side lane should return normally')
  assert_eq(rt:settlement_cell(tensor_nack.settlement).state, 'selected', 'with_nack inside tensor should settle selected')

  assert_eq(all_got[1][1], 'all-protected', 'protected all lane should return normally')
  assert_eq(all_got[2][1], 'all-side', 'all side lane should return normally')
  assert_eq(rt:settlement_cell(all_nack.settlement).state, 'selected', 'with_nack inside all should settle selected')
end

local function test_with_nack_and_guard_interactions()
  local rt = Runtime.new()
  rt.quiet_deadlock = true
  local got1, got2

  rt:spawn(function()
    got1 = Op.perform(Op.guard(function()
      return Op.with_nack(function()
        return Op.always('guard-outer')
      end)
    end))
  end, 'guard-contains-with-nack')

  rt:spawn(function()
    got2 = Op.perform(Op.with_nack(function()
      return Op.guard(function()
        return Op.always('guard-inner')
      end)
    end))
  end, 'with-nack-contains-guard')

  rt:run()
  assert_eq(got1, 'guard-outer', 'with_nack inside guard should behave as returned op')
  assert_eq(got2, 'guard-inner', 'guard inside with_nack should remain proof-only')
end

local function test_proof_search_is_tri_valued_and_budgeted()
  local rt = Runtime.new()
  local ch = Channel.new('proof-search-budget')

  local receiver = rt:spawn(function()
    Op.perform(ch:get_op())
  end, 'budget-receiver')
  drain_runnable(rt)

  local proof = first_proof_for(receiver)
  local budgeted = ProofSearch.new(rt, proof, 0):run()
  assert_eq(budgeted.status, 'budget', 'zero-budget proof search should report budget')

  local absent = ProofSearch.new(rt, proof):run()
  assert_eq(absent.status, 'absent', 'unmatched get should prove absence in closed current generation')
  assert_eq(absent.generation, rt.generation, 'absence proof should record current generation')
end

local function test_absence_is_generation_stable_not_timeless()
  local rt = Runtime.new()
  local ch = Channel.new('proof-search-generation')

  local receiver = rt:spawn(function()
    Op.perform(ch:get_op())
  end, 'generation-receiver')
  drain_runnable(rt)

  local absent = ProofSearch.new(rt, first_proof_for(receiver)):run()
  assert_eq(absent.status, 'absent', 'initial receiver-only search should prove absence')
  local absent_generation = absent.generation

  rt:spawn(function()
    Op.perform(ch:put_op('x'))
  end, 'generation-sender')
  drain_runnable(rt)

  assert(absent_generation ~= rt.generation, 'old absence proof should be invalid after generation change')

  local found = ProofSearch.new(rt, first_proof_for(receiver)):run()
  assert_eq(found.status, 'found', 'new sender should make a closed proof available')
  assert(found.world:is_committable(), 'worlds without preference obligations should be committable')
end

local function test_tensor_self_rendezvous_succeeds()
  local rt = Runtime.new()
  local ch = Channel.new('tensor-self')
  local got

  rt:spawn(function()
    got = Op.perform(Op.tensor({ ch:put_op('x'), ch:get_op() }))
  end, 'tensor-root')

  rt:run()

  assert(type(got) == 'table', 'tensor should return lane result table')
  assert_eq(got[1][1], true, 'put lane result')
  assert_eq(got[2][1], 'x', 'get lane result')
end

local function test_all_self_rendezvous_fails()
  local rt = Runtime.new()
  rt.quiet_deadlock = true
  local ch = Channel.new('all-self')

  rt:spawn(function()
    Op.perform(Op.all({ ch:put_op('x'), ch:get_op() }))
  end, 'all-root')

  local ok, err = pcall(function() rt:run() end)
  assert(ok == false, 'all self-rendezvous should deadlock')
  assert(tostring(err):match('deadlock'), 'expected deadlock error, got ' .. tostring(err))
end


local function test_tensor_join_feeds_transactional_continuation()
  local rt = Runtime.new()
  local internal = Channel.new('tensor-join-internal')
  local out = Channel.new('tensor-join-out')
  local received

  rt:spawn(function()
    local ok = Op.perform(
      Op.tensor({ internal:put_op('x'), internal:get_op() }):and_then(function(results)
        return out:put_op(results[2][1])
      end)
    )
    assert(ok == true, 'tensor continuation put should return true')
  end, 'tensor-join-root')

  rt:spawn(function()
    received = Op.perform(out:get_op())
  end, 'tensor-join-receiver')

  rt:run()
  assert_eq(received, 'x', 'tensor join should feed continuation inside same transaction')
end

local function test_all_join_feeds_transactional_continuation_after_external_cuts()
  local rt = Runtime.new()
  local a = Channel.new('all-join-a')
  local b = Channel.new('all-join-b')
  local out = Channel.new('all-join-out')
  local received

  rt:spawn(function()
    local ok = Op.perform(
      Op.all({ a:get_op(), b:get_op() }):and_then(function(results)
        return out:put_op(results[1][1] .. results[2][1])
      end)
    )
    assert(ok == true, 'all continuation put should return true')
  end, 'all-join-root')

  rt:spawn(function() Op.perform(a:put_op('A')) end, 'all-sender-a')
  rt:spawn(function() Op.perform(b:put_op('B')) end, 'all-sender-b')
  rt:spawn(function() received = Op.perform(out:get_op()) end, 'all-join-receiver')

  rt:run()
  assert_eq(received, 'AB', 'all join should feed continuation after external cuts')
end


local function test_wrap_boundary_transforms_after_commit()
  local rt = Runtime.new()
  local ch = Channel.new('wrap-ch')
  local got
  local ran = false

  rt:spawn(function()
    got = Op.perform(ch:get_op():wrap(function(x)
      ran = true
      return x .. '!'
    end))
  end, 'wrap-receiver')

  rt:spawn(function()
    Op.perform(ch:put_op('x'))
  end, 'wrap-sender')

  rt:run()
  assert(ran == true, 'wrap boundary should run after commit')
  assert_eq(got, 'x!', 'wrap should transform resumed value')
end

local function test_wrap_boundary_rejects_transactional_continuation()
  local ch = Channel.new('wrap-reject')
  local ok, err = pcall(function()
    return ch:get_op():wrap(function(x) return x end):and_then(function(x)
      return Op.always(x)
    end)
  end)
  assert(ok == false, 'wrap:and_then should be rejected')
  assert(tostring(err):match('wrap boundary'), 'expected wrap boundary error, got ' .. tostring(err))

  ok, err = pcall(function()
    return ch:get_op():wrap(function(x) return x end):map(function(x) return x end)
  end)
  assert(ok == false, 'wrap:map should be rejected')
  assert(tostring(err):match('wrap boundary'), 'expected wrap boundary error, got ' .. tostring(err))
end

local function test_wrap_boundary_is_branch_local()
  local rt = Runtime.new()
  local ch = Channel.new('wrap-branch')
  local got
  local ran = false

  rt:spawn(function()
    got = Op.perform(Op.choice(
      Op.always('plain'),
      ch:get_op():wrap(function(x)
        ran = true
        return x .. '!'
      end)
    ))
  end, 'wrap-choice')

  rt:run()
  assert_eq(got, 'plain', 'plain branch should commit')
  assert(ran == false, 'wrap should not run for unchosen branch')
end

local function test_wrap_boundary_can_perform_after_commit()
  local rt = Runtime.new()
  local ch = Channel.new('wrap-perform-in')
  local out = Channel.new('wrap-perform-out')
  local got
  local observed

  rt:spawn(function()
    got = Op.perform(ch:get_op():wrap(function(x)
      local ok = Op.perform(out:put_op(x .. '!'))
      assert(ok == true, 'post-commit wrapper put should complete')
      return x .. '?'
    end))
  end, 'wrap-performing-root')

  rt:spawn(function()
    Op.perform(ch:put_op('x'))
  end, 'wrap-performing-sender')

  rt:spawn(function()
    observed = Op.perform(out:get_op())
  end, 'wrap-performing-observer')

  rt:run()
  assert_eq(observed, 'x!', 'wrapper should be able to perform after commit')
  assert_eq(got, 'x?', 'wrapper should transform original perform result')
end


local function test_wrap_boundary_after_commit_event_order()
  local rt = Runtime.new()
  rt.quiet_deadlock = true
  local ch = Channel.new('wrap-order-ch')
  local order = {}

  local old_print_event = core.print_event
  core.print_event = function(event)
    if event.tag == 'order.event' then
      order[#order + 1] = 'commit'
    else
      old_print_event(event)
    end
  end

  rt:spawn(function()
    local got = Op.perform(
      ch:get_op():and_then(function(x)
        return Op.emit({ tag = 'order.event' }):and_then(function()
          return Op.always(x)
        end)
      end):wrap(function(x)
        order[#order + 1] = 'wrap'
        return x
      end)
    )
    assert_eq(got, 'x', 'order wrap value')
  end, 'wrap-order-receiver')

  rt:spawn(function() Op.perform(ch:put_op('x')) end, 'wrap-order-sender')
  rt:run()
  core.print_event = old_print_event

  assert_eq(order[1], 'commit', 'commit event should run before wrapper')
  assert_eq(order[2], 'wrap', 'wrapper should run after commit event')
end


local function test_search_phase_forbids_perform_and_spawn()
  local rt = Runtime.new()
  rt.quiet_deadlock = true
  local ch = Channel.new('search-phase-guard')

  rt:spawn(function()
    Op.perform(Op.always('x'):and_then(function()
      return Op.perform(ch:get_op())
    end))
  end, 'bad-perform-during-search')

  drain_runnable(rt)
  local ok, err = pcall(function() rt:try_commit_one() end)
  assert(ok == false, 'perform during proof search expansion should fail')
  assert(tostring(err):match('proof search'), 'expected proof search error, got ' .. tostring(err))

  rt = Runtime.new()
  rt:spawn(function()
    Op.perform(Op.always('x'):and_then(function()
      rt:spawn(function() end, 'bad-spawned-during-search')
      return Op.always('ok')
    end))
  end, 'bad-spawn-during-search')

  drain_runnable(rt)
  ok, err = pcall(function() rt:try_commit_one() end)
  assert(ok == false, 'spawn during proof search expansion should fail')
  assert(tostring(err):match('proof search'), 'expected proof search error, got ' .. tostring(err))
end

local function test_post_commit_phase_is_explicit_in_wrapper()
  local rt = Runtime.new()
  local ch = Channel.new('post-commit-phase')
  local out = Channel.new('post-commit-phase-out')
  local observed
  local saw_post_commit_before = false
  local saw_post_commit_after = false

  rt:spawn(function()
    local got = Op.perform(ch:get_op():wrap(function(x)
      saw_post_commit_before = core._test.current_task() and core._test.current_task().phase == 'post_commit'
      local ok = Op.perform(out:put_op(x .. '!'))
      assert(ok == true, 'post-commit phase nested put should complete')
      saw_post_commit_after = core._test.current_task() and core._test.current_task().phase == 'post_commit'
      return x .. '?'
    end))
    assert_eq(got, 'x?', 'post-commit phase wrapper value')
  end, 'post-commit-phase-root')

  rt:spawn(function() Op.perform(ch:put_op('x')) end, 'post-commit-phase-sender')
  rt:spawn(function() observed = Op.perform(out:get_op()) end, 'post-commit-phase-observer')
  rt:run()

  assert_eq(observed, 'x!', 'nested post-commit perform observed')
  assert(saw_post_commit_before == true, 'wrapper should run in explicit post_commit phase before nested perform')
  assert(saw_post_commit_after == true, 'wrapper should remain in post_commit phase after nested perform')
end


local function test_or_else_primary_done_wins()
  local rt = Runtime.new()
  local got

  rt:spawn(function()
    got = Op.perform(Op.always('primary'):or_else(Op.always('fallback')))
  end, 'prefer-primary-done')

  rt:run()
  assert_eq(got, 'primary', 'or_else primary should win when immediately available')
end

local function test_or_else_fallback_commits_after_absence_proof()
  local rt = Runtime.new()
  local ch = Channel.new('prefer-fallback-absent')
  local got

  rt:spawn(function()
    got = Op.perform(ch:get_op():or_else(Op.always('fallback')))
  end, 'prefer-fallback-root')

  rt:run()
  assert_eq(got, 'fallback', 'or_else fallback should commit after primary absence is proved')
end

local function test_or_else_primary_rendezvous_beats_fallback()
  local rt = Runtime.new()
  local ch = Channel.new('prefer-primary-rendezvous')
  local got

  rt:spawn(function()
    got = Op.perform(ch:get_op():or_else(Op.always('fallback')))
  end, 'prefer-receiver')

  rt:spawn(function()
    Op.perform(ch:put_op('primary-value'))
  end, 'prefer-sender')

  rt:run()
  assert_eq(got, 'primary-value', 'available primary rendezvous should beat fallback')
end

local function test_or_else_fallback_absence_can_report_budget()
  local rt = Runtime.new()
  local ch = Channel.new('prefer-budget')

  local receiver = rt:spawn(function()
    Op.perform(ch:get_op():or_else(Op.always('fallback')))
  end, 'prefer-budget-root')
  drain_runnable(rt)

  local result = rt:search_task(receiver)
  assert_eq(result.status, 'found', 'fallback world should be valid before committability proof')
  assert(#result.world:preference_obligations() > 0, 'fallback world should carry preference obligation')

  local proof = rt:prove_committable(result.world, JudgementContext.new(rt, 0))
  assert_eq(proof.status, 'budget', 'zero-budget absence proof should report budget')
end

local function test_or_else_site_address_is_replay_stable()
  local ch = Channel.new('prefer-address')
  local operation = ch:get_op():or_else(Op.always('fallback'))
  local frames1 = expand_expr(operation, EvidenceDelta.empty(), ExpansionContext.root('prefer-address-root'))
  local frames2 = expand_expr(operation, EvidenceDelta.empty(), ExpansionContext.root('prefer-address-root'))
  local site1, site2
  for _, f in ipairs(frames1) do
    if f.evidence and f.evidence.pre_commit.obligations and f.evidence.pre_commit.obligations[1] then site1 = f.evidence.pre_commit.obligations[1].site end
  end
  for _, f in ipairs(frames2) do
    if f.evidence and f.evidence.pre_commit.obligations and f.evidence.pre_commit.obligations[1] then site2 = f.evidence.pre_commit.obligations[1].site end
  end
  assert(site1 and site2, 'fallback branch should expose preference obligation site')
  assert_eq(site1, site2, 'PreferLink site address should be replay-stable')
end


local function nested_or_else_op(outer, inner)
  return outer:get_op():or_else(
    inner:get_op():or_else(Op.always('fallback'))
  )
end

local function test_nested_or_else_obligation_prefixes()
  local rt = Runtime.new()
  local outer = Channel.new('nested-prefix-outer')
  local inner = Channel.new('nested-prefix-inner')

  local receiver = rt:spawn(function()
    Op.perform(nested_or_else_op(outer, inner))
  end, 'nested-prefix-root')
  drain_runnable(rt)

  local result = rt:search_task(receiver)
  assert_eq(result.status, 'found', 'nested fallback world should be valid')

  local obligations = result.world:preference_obligations()
  assert_eq(#obligations, 2, 'nested fallback should create two preference obligations')

  local outer_obligation = obligations[1]
  local inner_obligation = obligations[2]

  assert_eq(#outer_obligation.prefix, 0, 'outer fallback obligation prefix should be empty')
  assert_eq(outer_obligation.fallback_entry.site, outer_obligation.site, 'outer fallback entry should point at outer site')
  assert_eq(outer_obligation.fallback_entry.branch, 'fallback', 'outer fallback entry should record fallback branch')
  assert_eq(#outer_obligation.fallback_entry.prefix, 0, 'outer fallback entry prefix should be empty')

  assert_eq(#inner_obligation.prefix, 1, 'inner fallback obligation should preserve outer fallback prefix')
  assert_eq(inner_obligation.prefix[1].site, outer_obligation.site, 'inner prefix should mention outer site')
  assert_eq(inner_obligation.prefix[1].branch, 'fallback', 'inner prefix should force outer fallback')
  assert_eq(inner_obligation.fallback_entry.site, inner_obligation.site, 'inner fallback entry should point at inner site')
  assert_eq(inner_obligation.fallback_entry.branch, 'fallback', 'inner fallback entry should record fallback branch')
end

local function test_forced_decisions_for_nested_obligation()
  local rt = Runtime.new()
  local outer = Channel.new('nested-forced-outer')
  local inner = Channel.new('nested-forced-inner')

  local receiver = rt:spawn(function()
    Op.perform(nested_or_else_op(outer, inner))
  end, 'nested-forced-root')
  drain_runnable(rt)

  local result = rt:search_task(receiver)
  assert_eq(result.status, 'found', 'nested fallback world should be valid for forced decision test')
  local obligations = result.world:preference_obligations()
  local outer_obligation = obligations[1]
  local inner_obligation = obligations[2]

  local forced_outer = assert(forced_decisions_for_obligation(outer_obligation))
  assert_eq(forced_outer[outer_obligation.site], 'primary', 'outer obligation should force outer primary')

  local forced_inner = assert(forced_decisions_for_obligation(inner_obligation))
  assert_eq(forced_inner[outer_obligation.site], 'fallback', 'inner obligation should replay outer fallback prefix')
  assert_eq(forced_inner[inner_obligation.site], 'primary', 'inner obligation should force inner primary')
end

local function test_nested_or_else_inner_primary_under_outer_fallback()
  local rt = Runtime.new()
  local outer = Channel.new('nested-outer-absent')
  local inner = Channel.new('nested-inner-present')
  local got

  rt:spawn(function()
    got = Op.perform(nested_or_else_op(outer, inner))
  end, 'nested-inner-receiver')

  rt:spawn(function()
    Op.perform(inner:put_op('inner-primary'))
  end, 'nested-inner-sender')

  rt:run()
  assert_eq(got, 'inner-primary', 'inner primary should win under outer=fallback')
end

local function test_nested_or_else_outer_primary_dominates_inner_fallback()
  local rt = Runtime.new()
  local outer = Channel.new('nested-outer-present')
  local inner = Channel.new('nested-inner-irrelevant')
  local got

  rt:spawn(function()
    got = Op.perform(nested_or_else_op(outer, inner))
  end, 'nested-outer-receiver')

  rt:spawn(function()
    Op.perform(outer:put_op('outer-primary'))
  end, 'nested-outer-sender')

  rt:run()
  assert_eq(got, 'outer-primary', 'outer primary should dominate nested fallback world')
end


local function test_product_base_evidence_not_duplicated()
  local rt = Runtime.new()
  local ch = Channel.new('product-base-no-dup')

  local operation = ch:get_op():or_else(Op.always('fallback')):and_then(function()
    return Op.tensor({ Op.always('a'), Op.always('b') })
  end)

  local receiver = rt:spawn(function()
    Op.perform(operation)
  end, 'product-base-no-dup-root')
  drain_runnable(rt)

  local result = rt:search_task(receiver)
  assert_eq(result.status, 'found', 'product fallback world should be valid before committability proof')

  local obligations = result.world:preference_obligations()
  assert_eq(#obligations, 1, 'pre-product fallback obligation should appear once, not once per lane')
end

local function test_product_lane_obligations_are_lane_local()
  local rt = Runtime.new()
  local a = Channel.new('lane-a')
  local b = Channel.new('lane-b')

  local operation = Op.tensor({
    a:get_op():or_else(Op.always('fa')),
    b:get_op():or_else(Op.always('fb')),
  })

  local receiver = rt:spawn(function()
    Op.perform(operation)
  end, 'lane-local-prefer-root')
  drain_runnable(rt)

  local result = rt:search_task(receiver)
  assert_eq(result.status, 'found', 'lane-local fallback world should be valid')

  local obligations = result.world:preference_obligations()
  assert_eq(#obligations, 2, 'each lane fallback should create exactly one local obligation')
  assert(obligations[1].site ~= obligations[2].site, 'lane PreferLink sites should be distinct')
end

local function test_search_committable_task_skips_rejected_candidate()
  local rt = Runtime.new()
  local got

  rt:spawn(function()
    got = Op.perform(Op.choice(Op.always('first'), Op.always('second')))
  end, 'skip-rejected-candidate-root')
  drain_runnable(rt)

  local old_prove = rt.prove_committable
  rt.prove_committable = function(self, world, judgement)
    local value = world.entries[1].frame.values[1]
    if value == 'first' then
      return { status = 'dominated', world = world, reason = 'test rejection' }
    end
    return old_prove(self, world, judgement)
  end

  local status = rt:try_commit_one()
  rt.prove_committable = old_prove

  assert_eq(status, 'committed', 'runtime should continue past a dominated candidate to a committable candidate')
  while #rt.runnable > 0 do
    local task = table.remove(rt.runnable, 1)
    rt:resume_task(task)
  end
  assert_eq(got, 'second', 'the later committable candidate should be committed')
end


local function fake_task(id, op, label)
  return {
    id = id,
    name = label or ('fake-task-' .. tostring(id)),
    op = op,
    root_label = label or ('fake-task-' .. tostring(id)),
    attempt_id = 1,
    parked = true,
  }
end

local function fake_obligation(task)
  return {
    kind = 'prefer_absence',
    task = task,
    site = 'test/nonexistent/prefer-site',
    prefix = {},
    force = 'primary',
  }
end

local function test_preference_obligation_looks_for_committable_not_merely_valid()
  local rt = Runtime.new()
  local task = fake_task(9001, Op.always('valid-but-not-committable'), 'preferred-valid-only')
  local obligation = fake_obligation(task)

  local old_prove = rt.prove_committable
  rt.prove_committable = function(self, world, judgement)
    local value = world.entries[1].frame.values[1]
    if value == 'valid-but-not-committable' then
      return { status = 'dominated', world = world, reason = 'test valid leaf is not committable' }
    end
    return old_prove(self, world, judgement)
  end

  local result = rt:prove_obligation(obligation, JudgementContext.new(rt))
  rt.prove_committable = old_prove

  assert_eq(result.status, 'discharged', 'a merely valid preferred proof must not dominate fallback')
end

local function test_preference_obligation_continues_to_later_committable_preferred_world()
  local rt = Runtime.new()
  local task = fake_task(9002,
    Op.choice(Op.always('valid-but-not-committable'), Op.always('preferred-committable')),
    'preferred-continues-to-committable')
  local obligation = fake_obligation(task)

  local old_prove = rt.prove_committable
  rt.prove_committable = function(self, world, judgement)
    local value = world.entries[1].frame.values[1]
    if value == 'valid-but-not-committable' then
      return { status = 'dominated', world = world, reason = 'test valid leaf is not committable' }
    end
    return old_prove(self, world, judgement)
  end

  local result = rt:prove_obligation(obligation, JudgementContext.new(rt))
  rt.prove_committable = old_prove

  assert_eq(result.status, 'dominated', 'a later committable preferred world should dominate fallback')
  assert_eq(result.world.entries[1].frame.values[1], 'preferred-committable', 'obligation should return the committable preferred world, not the first valid leaf')
end

local function test_judgement_context_shares_fuel_across_committability_searches()
  local rt = Runtime.new()
  local judgement = JudgementContext.new(rt, 1)
  local first = fake_task(9003, Op.always('first'), 'shared-fuel-first')
  local second = fake_task(9004, Op.always('second'), 'shared-fuel-second')

  local first_result = rt:search_committable_task(first, {}, judgement)
  assert_eq(first_result.status, 'found', 'first committability search should consume the single fuel unit')

  local second_result = rt:search_committable_task(second, {}, judgement)
  assert_eq(second_result.status, 'budget', 'second committability search should see the same exhausted judgement fuel')
end

local function test_cyclic_committability_judgement_reports_budget()
  local rt = Runtime.new()
  local judgement = JudgementContext.new(rt)
  local task = fake_task(9005, Op.always('cycle'), 'cyclic-judgement')
  local key = committable_search_key(task, nil, judgement.generation)
  judgement.stack[key] = true

  local result = rt:search_committable_task(task, nil, judgement)
  assert_eq(result.status, 'budget', 'recursive committability judgement should be unknown, not absent')
  assert(tostring(result.reason):match('cyclic'), 'expected cyclic judgement reason')
end


-- Resource used to assert the base+delta read discipline for Op.access.  Its
-- response reports the visible count, while its returned fragment contributes
-- exactly one local tick.
local ViewCounter = {}
ViewCounter.__index = ViewCounter

function ViewCounter.new()
  return setmetatable({ committed = 0 }, ViewCounter)
end

function ViewCounter:tick()
  return Op.access(self, { tag = 'tick' })
end

function ViewCounter:empty_fragment()
  return { count = 0 }
end

function ViewCounter:merge_fragments(a, b)
  return true, { count = (a and a.count or 0) + (b and b.count or 0) }
end

function ViewCounter:step_fragment(fragment, _request)
  local current = fragment and fragment.count or 0
  return true, { value = current }, { count = current + 1 }
end

function ViewCounter:step_fragment_with_view(view_fragment, local_fragment, _request)
  local visible = view_fragment and view_fragment.count or 0
  local local_count = local_fragment and local_fragment.count or 0
  return true, { value = visible }, { count = local_count + 1 }
end

function ViewCounter:validate_fragment(_fragment)
  return true
end

function ViewCounter:commit_fragment(fragment)
  self.committed = self.committed + (fragment and fragment.count or 0)
end

local function test_product_lane_access_reads_base_but_writes_delta()
  local rt = Runtime.new()
  local counter = ViewCounter.new()
  local observed

  rt:spawn(function()
    observed = Op.perform(counter:tick():and_then(function(before_product)
      assert_eq(before_product, 0, 'first access should see empty fragment')
      return Op.tensor({
        counter:tick(),
        Op.always('other-lane'),
      })
    end))
  end, 'fragment-view-root')

  rt:run()

  assert_eq(observed[1][1], 1, 'product lane access should read base_evidence + local delta')
  assert_eq(counter.committed, 2, 'product lane access should commit base once plus one lane delta')
end


local function test_product_lane_wrap_transforms_after_commit()
  local rt = Runtime.new()
  local a = Channel.new('lane-wrap-a')
  local b = Channel.new('lane-wrap-b')
  local got
  local ran = false

  rt:spawn(function()
    got = Op.perform(Op.tensor({
      a:get_op():wrap(function(x)
        ran = true
        return x .. '!'
      end),
      b:get_op(),
    }))
  end, 'lane-wrap-root')

  rt:spawn(function() Op.perform(a:put_op('A')) end, 'lane-wrap-sender-a')
  rt:spawn(function() Op.perform(b:put_op('B')) end, 'lane-wrap-sender-b')
  rt:run()

  assert(ran == true, 'lane-local wrapper should run after product commit')
  assert_eq(got[1][1], 'A!', 'lane-local wrapper should transform only lane 1')
  assert_eq(got[2][1], 'B', 'unwrapped lane should return raw value')
end

local function test_product_lane_wrap_can_perform_after_commit()
  local rt = Runtime.new()
  local a = Channel.new('lane-wrap-perform-a')
  local b = Channel.new('lane-wrap-perform-b')
  local c = Channel.new('lane-wrap-perform-c')
  local got

  rt:spawn(function()
    got = Op.perform(Op.tensor({
      a:get_op():wrap(function(x)
        local y = Op.perform(c:get_op())
        return x .. y
      end),
      b:get_op(),
    }))
  end, 'lane-wrap-performing-root')

  rt:spawn(function() Op.perform(a:put_op('A')) end, 'lane-wrap-performing-sender-a')
  rt:spawn(function() Op.perform(b:put_op('B')) end, 'lane-wrap-performing-sender-b')
  rt:spawn(function() Op.perform(c:put_op('C')) end, 'lane-wrap-performing-sender-c')
  rt:run()

  assert_eq(got[1][1], 'AC', 'lane-local wrapper may perform a fresh transaction before outer perform returns')
  assert_eq(got[2][1], 'B', 'other product lane should remain raw')
end

local function test_product_lane_wrap_rejects_transactional_continuation()
  local rt = Runtime.new()
  rt.quiet_deadlock = true

  rt:spawn(function()
    Op.perform(Op.tensor({
      Op.always('a'):wrap(function(x) return x .. '!' end),
      Op.always('b'),
    }):and_then(function(results)
      return Op.always(results)
    end))
  end, 'lane-wrap-bad-cont')

  local ok, err = pcall(function() drain_runnable(rt) end)
  assert(ok == false, 'boundary-tainted product should reject transactional continuation')
  assert(tostring(err):match('boundary lane'), 'expected boundary lane error, got ' .. tostring(err))
end

local function test_product_lane_and_product_wrap_compose_post_commit()
  local rt = Runtime.new()
  local got

  rt:spawn(function()
    got = Op.perform(Op.tensor({
      Op.always('a'):wrap(function(x) return x .. '1' end),
      Op.always('b'),
    }):wrap(function(results)
      return results[1][1] .. results[2][1]
    end))
  end, 'lane-and-product-wrap')

  rt:run()
  assert_eq(got, 'a1b', 'lane-local post program should run before product-level wrapper')
end


local function test_world_owns_phase_shaped_evidence_and_resumptions()
  local rt = Runtime.new()
  rt.quiet_deadlock = true
  local task = rt:spawn(function()
    Op.perform(Op.emit({ tag = 'evidence.descriptor' }))
  end, 'evidence-world')

  drain_runnable(rt)
  local result = rt:search_committable_task(task, nil, JudgementContext.new(rt))
  assert_eq(result.status, 'found', 'simple emit should produce a committable world')
  local world = result.world

  assert(world.evidence ~= nil, 'world should carry one evidence certificate')
  assert(world.evidence.resources ~= nil, 'evidence should have resource phase')
  assert(world.evidence.pre_commit ~= nil, 'evidence should have pre-commit phase')
  assert(world.evidence.commit ~= nil, 'evidence should have commit phase')
  assert_eq(#world.evidence.commit.descriptors, 1, 'emit should become a commit descriptor')
  assert_eq(world.evidence.commit.descriptors[1].tag, 'evidence.descriptor')
  assert_eq(#world.resumptions, 1, 'world should carry one per-root resumption certificate')
  assert_eq(world.resumptions[1].task, task)

  local rt2 = Runtime.new()
  rt2.quiet_deadlock = true
  local wrapped_task = rt2:spawn(function()
    Op.perform(Op.always('x'):wrap(function(x) return x .. '!' end))
  end, 'wrapped-resumption-world')

  drain_runnable(rt2)
  local wrapped_result = rt2:search_committable_task(wrapped_task, nil, JudgementContext.new(rt2))
  assert_eq(wrapped_result.status, 'found', 'wrapped always should produce a committable world')
  local wrapped_world = wrapped_result.world
  assert(wrapped_world.evidence.post == nil,
    'global WorldEvidence must not carry post programs')
  assert_eq(#wrapped_world.resumptions, 1, 'wrapped world should still have a per-root resumption')
  assert(not PostProgram.is_identity(wrapped_world.resumptions[1].post_program),
    'per-root resumption should carry the post program')
end

local DescriptorResource = {}
DescriptorResource.__index = DescriptorResource

function DescriptorResource.new()
  return setmetatable({}, DescriptorResource)
end

function DescriptorResource:empty_fragment() return {} end
function DescriptorResource:merge_fragments(_, fragment) return true, fragment end
function DescriptorResource:validate_fragment(_) return true end
function DescriptorResource:commit_fragment(_) end

function DescriptorResource:step_fragment(fragment, _)
  return true, {
    value = 'ok',
    descriptors = { { tag = 'resource.descriptor' } },
  }, fragment
end

local function test_resource_responses_use_descriptors()
  local rt = Runtime.new()
  rt.quiet_deadlock = true
  local resource = DescriptorResource.new()
  local task = rt:spawn(function()
    Op.perform(Op.access(resource, {}))
  end, 'descriptor-response-world')

  drain_runnable(rt)
  local result = rt:search_committable_task(task, nil, JudgementContext.new(rt))
  assert_eq(result.status, 'found', 'descriptor resource should produce a world')
  local descriptors = result.world.evidence.commit.descriptors
  assert_eq(#descriptors, 1, 'resource response descriptors should become commit descriptors')
  assert_eq(descriptors[1].tag, 'resource.descriptor')
end

local function test_occurrence_refs_are_stable_and_prefix_sensitive()
  local task = { id = 7001, attempt_id = 3 }
  local ctx = ExpansionContext.root('occurrence-root', task):child('site')
  local e1 = EvidenceDelta.empty()
  local e2 = EvidenceDelta.empty()

  local a = OccurrenceRef.new('test', ctx, e1)
  local b = OccurrenceRef.new('test', ctx, e2)
  assert_eq(a.key, b.key, 'same root/site/prefix should produce stable occurrence key')

  local decided = e1:clone_local()
  decided.decisions['branch/site'] = 'fallback'
  decided.decision_path[#decided.decision_path + 1] = {
    site = 'branch/site',
    branch = 'fallback',
    prefix = {},
  }
  local c = OccurrenceRef.new('test', ctx, decided)
  assert(a.key ~= c.key, 'decision prefix should distinguish occurrence identity')
end

local function test_settlement_selected_and_published_lost_are_commit_interpretation()
  local rt = Runtime.new()
  local selected_task = {
    id = 8001,
    name = 'selected-settlement-task',
    parked = true,
    values = pack(),
  }
  local selected_attempt = RootAttempt.new(selected_task, Op.always('ok'), rt.generation, 1)
  selected_task.attempt = selected_attempt
  selected_task.attempt_id = selected_attempt.id
  rt.waiting = { selected_task }
  rt.waiting_set[selected_task] = true

  local selected_ctx = ExpansionContext.root('selected-settlement-root', selected_task, nil, selected_attempt)
  local selected_evidence = EvidenceDelta.empty()
  local selected_ref = SettlementRef.new('settlement', selected_ctx, selected_evidence)
  selected_evidence:add_selected_settlement(selected_ref)

  local selected_world = core.World.from_entries({
    { task = selected_task, frame = { kind = 'done', values = pack('ok'), evidence = selected_evidence, after_post_program = core.PostProgram.identity() } }
  }, {})
  assert(selected_world, 'selected settlement world should build')
  selected_world:commit(rt)
  assert_eq(rt:settlement_cell(selected_ref).state, 'selected', 'selected settlement evidence should settle selected at commit')

  local rt2 = Runtime.new()
  local lost_task = {
    id = 8002,
    name = 'lost-settlement-task',
    parked = true,
    values = pack(),
  }
  local lost_attempt = RootAttempt.new(lost_task, Op.always('plain'), rt2.generation, 1)
  lost_task.attempt = lost_attempt
  lost_task.attempt_id = lost_attempt.id
  rt2.waiting = { lost_task }
  rt2.waiting_set[lost_task] = true

  local lost_ctx = ExpansionContext.root('lost-settlement-root', lost_task, nil, lost_attempt)
  local lost_ref = SettlementRef.new('settlement', lost_ctx, EvidenceDelta.empty())
  rt2:publish_settlement(lost_ref)

  local plain_evidence = EvidenceDelta.empty()
  local plain_world = core.World.from_entries({
    { task = lost_task, frame = { kind = 'done', values = pack('plain'), evidence = plain_evidence, after_post_program = core.PostProgram.identity() } }
  }, {})
  assert(plain_world, 'plain world should build')
  plain_world:commit(rt2)
  assert_eq(rt2:settlement_cell(lost_ref).state, 'lost', 'published unselected settlement should settle lost at commit')
end

local function test_root_attempt_world_evidence_resumption_and_commit_plan()
  local rt = Runtime.new()
  rt.quiet_deadlock = true
  local task = rt:spawn(function()
    local value = Op.perform(Op.always('x'):wrap(function(x) return x .. '!' end))
    assert_eq(value, 'x!', 'post program should still run after CommitPlan resumes task')
  end, 'architecture-root-attempt')

  drain_runnable(rt)
  assert(task.attempt ~= nil, 'parking should create a RootAttempt')
  assert(getmetatable(task.attempt) == RootAttempt, 'task.attempt should be a RootAttempt')
  assert_eq(task.attempt.state, 'parked', 'RootAttempt should be parked before commit')

  local result = rt:search_committable_task(task, nil, JudgementContext.new(rt))
  assert_eq(result.status, 'found', 'wrapped always should produce a committable world')
  local world = result.world
  assert(getmetatable(world.evidence) == WorldEvidence, 'world.evidence should be WorldEvidence')
  assert(world.evidence.post == nil, 'WorldEvidence should not carry post evidence')
  assert_eq(#world.resumptions, 1, 'world should have one ResumptionEvidence')
  assert(getmetatable(world.resumptions[1]) == ResumptionEvidence, 'resumption should be ResumptionEvidence')
  assert_eq(world.resumptions[1].attempt, task.attempt, 'resumption should point at the RootAttempt')

  local plan, reason = CommitPlan.prepare(world, rt)
  assert(plan, reason or 'CommitPlan should prepare')
  assert(getmetatable(plan) == CommitPlan, 'CommitPlan.prepare should return a CommitPlan')
  plan:apply(rt)
  assert_eq(task.attempt.state, 'committed', 'CommitPlan.apply should mark RootAttempt committed')
  drain_runnable(rt)
end

local function test_commit_plan_revalidates_root_attempt_ownership()
  local rt = Runtime.new()
  rt.quiet_deadlock = true
  local task = rt:spawn(function()
    Op.perform(Op.always('x'))
  end, 'stale-attempt-root')

  drain_runnable(rt)
  local old_attempt = task.attempt
  local result = rt:search_committable_task(task, nil, JudgementContext.new(rt))
  assert_eq(result.status, 'found', 'old attempt should produce a world before staleness')

  local plan, reason = CommitPlan.prepare(result.world, rt)
  assert(plan, reason or 'initial CommitPlan should prepare')

  local newer_attempt = RootAttempt.new(task, Op.always('newer'), rt.generation, 999)
  task.attempt = newer_attempt
  task.attempt_id = newer_attempt.id
  task.parked = true

  local stale_plan, stale_reason = CommitPlan.prepare(result.world, rt)
  assert(stale_plan == nil, 'CommitPlan.prepare should reject stale attempt ownership')
  assert(tostring(stale_reason):match('stale'), 'expected stale attempt reason, got ' .. tostring(stale_reason))

  local ok, err = pcall(function() plan:apply(rt) end)
  assert(ok == false, 'CommitPlan.apply should revalidate stale attempt ownership before mutating')
  assert(tostring(err):match('stale'), 'expected stale attempt apply error, got ' .. tostring(err))
  assert_eq(old_attempt.state, 'parked', 'stale apply should not mutate old attempt state')
end

local function test_commit_plan_prepares_settlement_updates_before_apply()
  local rt = Runtime.new()
  rt.quiet_deadlock = true
  local task = rt:spawn(function()
    Op.perform(Op.always('settled'))
  end, 'settlement-plan-root')

  drain_runnable(rt)
  local ctx = ExpansionContext.root('settlement-plan-root', task, nil, task.attempt)
  local evidence = EvidenceDelta.empty()
  local selected_ref = SettlementRef.new('settlement', ctx, evidence)
  evidence:add_selected_settlement(selected_ref)

  local world = core.World.from_entries({
    { task = task, frame = { kind = 'done', values = pack('settled'), evidence = evidence, after_post_program = core.PostProgram.identity() } }
  }, {})
  assert(world, 'selected settlement plan world should build')

  local cell = rt:settlement_cell(selected_ref)
  assert_eq(cell.state, 'pending', 'settlement should be pending before plan apply')

  local plan, reason = CommitPlan.prepare(world, rt)
  assert(plan, reason or 'CommitPlan should prepare selected settlement update')
  assert_eq(#plan.settlement_updates, 1, 'CommitPlan.prepare should compute selected settlement update')
  assert_eq(plan.settlement_updates[1].state, 'selected', 'prepared settlement update should be selected')
  assert_eq(cell.state, 'pending', 'CommitPlan.prepare must not settle the cell')

  plan:apply(rt)
  assert_eq(cell.state, 'selected', 'CommitPlan.apply should interpret prepared settlement update')
end

local test_cases = {
  { name = 'test_derivation_addresses_are_stable', fn = test_derivation_addresses_are_stable },
  { name = 'test_bind_link_is_explicit_and_reduced_by_search', fn = test_bind_link_is_explicit_and_reduced_by_search },
  { name = 'test_map_link_is_explicit_and_reduced_by_search', fn = test_map_link_is_explicit_and_reduced_by_search },
  { name = 'test_map_is_transactional_before_commit_and_wrap_after_commit', fn = test_map_is_transactional_before_commit_and_wrap_after_commit },
  { name = 'test_map_callback_cannot_perform', fn = test_map_callback_cannot_perform },
  { name = 'test_bind_callback_must_return_op', fn = test_bind_callback_must_return_op },
  { name = 'test_guard_does_not_run_at_construction_and_runs_at_expansion', fn = test_guard_does_not_run_at_construction_and_runs_at_expansion },
  { name = 'test_guard_is_memoized_per_attempt_occurrence', fn = test_guard_is_memoized_per_attempt_occurrence },
  { name = 'test_guard_callback_must_return_op', fn = test_guard_callback_must_return_op },
  { name = 'test_guard_callback_cannot_perform_or_spawn', fn = test_guard_callback_cannot_perform_or_spawn },
  { name = 'test_or_else_function_fallback_is_guarded_and_memoized', fn = test_or_else_function_fallback_is_guarded_and_memoized },
  { name = 'test_with_nack_callback_timing_and_return_contract', fn = test_with_nack_callback_timing_and_return_contract },
  { name = 'test_with_nack_is_memoized_per_attempt_occurrence', fn = test_with_nack_is_memoized_per_attempt_occurrence },
  { name = 'test_with_nack_selected_and_nack_never_closes', fn = test_with_nack_selected_and_nack_never_closes },
  { name = 'test_with_nack_published_alternative_loses_and_nack_closes_later', fn = test_with_nack_published_alternative_loses_and_nack_closes_later },
  { name = 'test_with_nack_same_world_circularity_does_not_close', fn = test_with_nack_same_world_circularity_does_not_close },
  { name = 'test_with_nack_unrelated_commit_does_not_fire_pending_nack', fn = test_with_nack_unrelated_commit_does_not_fire_pending_nack },
  { name = 'test_with_nack_bind_created_occurrence_selects_without_publication', fn = test_with_nack_bind_created_occurrence_selects_without_publication },
  { name = 'test_with_nack_withdrawal_enables_nack', fn = test_with_nack_withdrawal_enables_nack },
  { name = 'test_with_nack_nested_parent_child_settlement', fn = test_with_nack_nested_parent_child_settlement },
  { name = 'test_with_nack_and_guard_interactions', fn = test_with_nack_and_guard_interactions },
  { name = 'test_nack_op_closes_inside_tensor_and_all', fn = test_nack_op_closes_inside_tensor_and_all },
  { name = 'test_with_nack_protected_occurrence_selects_inside_tensor_and_all', fn = test_with_nack_protected_occurrence_selects_inside_tensor_and_all },
  { name = 'test_proof_search_is_tri_valued_and_budgeted', fn = test_proof_search_is_tri_valued_and_budgeted },
  { name = 'test_absence_is_generation_stable_not_timeless', fn = test_absence_is_generation_stable_not_timeless },
  { name = 'test_search_phase_forbids_perform_and_spawn', fn = test_search_phase_forbids_perform_and_spawn },
  { name = 'test_tensor_self_rendezvous_succeeds', fn = test_tensor_self_rendezvous_succeeds },
  { name = 'test_all_self_rendezvous_fails', fn = test_all_self_rendezvous_fails },
  { name = 'test_tensor_join_feeds_transactional_continuation', fn = test_tensor_join_feeds_transactional_continuation },
  { name = 'test_all_join_feeds_transactional_continuation_after_external_cuts', fn = test_all_join_feeds_transactional_continuation_after_external_cuts },
  { name = 'test_wrap_boundary_transforms_after_commit', fn = test_wrap_boundary_transforms_after_commit },
  { name = 'test_wrap_boundary_rejects_transactional_continuation', fn = test_wrap_boundary_rejects_transactional_continuation },
  { name = 'test_wrap_boundary_is_branch_local', fn = test_wrap_boundary_is_branch_local },
  { name = 'test_wrap_boundary_can_perform_after_commit', fn = test_wrap_boundary_can_perform_after_commit },
  { name = 'test_wrap_boundary_after_commit_event_order', fn = test_wrap_boundary_after_commit_event_order },
  { name = 'test_post_commit_phase_is_explicit_in_wrapper', fn = test_post_commit_phase_is_explicit_in_wrapper },
  { name = 'test_or_else_primary_done_wins', fn = test_or_else_primary_done_wins },
  { name = 'test_or_else_fallback_commits_after_absence_proof', fn = test_or_else_fallback_commits_after_absence_proof },
  { name = 'test_or_else_primary_rendezvous_beats_fallback', fn = test_or_else_primary_rendezvous_beats_fallback },
  { name = 'test_or_else_fallback_absence_can_report_budget', fn = test_or_else_fallback_absence_can_report_budget },
  { name = 'test_or_else_site_address_is_replay_stable', fn = test_or_else_site_address_is_replay_stable },
  { name = 'test_nested_or_else_obligation_prefixes', fn = test_nested_or_else_obligation_prefixes },
  { name = 'test_forced_decisions_for_nested_obligation', fn = test_forced_decisions_for_nested_obligation },
  { name = 'test_nested_or_else_inner_primary_under_outer_fallback', fn = test_nested_or_else_inner_primary_under_outer_fallback },
  { name = 'test_nested_or_else_outer_primary_dominates_inner_fallback', fn = test_nested_or_else_outer_primary_dominates_inner_fallback },
  { name = 'test_product_base_evidence_not_duplicated', fn = test_product_base_evidence_not_duplicated },
  { name = 'test_product_lane_obligations_are_lane_local', fn = test_product_lane_obligations_are_lane_local },
  { name = 'test_search_committable_task_skips_rejected_candidate', fn = test_search_committable_task_skips_rejected_candidate },
  { name = 'test_preference_obligation_looks_for_committable_not_merely_valid', fn = test_preference_obligation_looks_for_committable_not_merely_valid },
  { name = 'test_preference_obligation_continues_to_later_committable_preferred_world', fn = test_preference_obligation_continues_to_later_committable_preferred_world },
  { name = 'test_judgement_context_shares_fuel_across_committability_searches', fn = test_judgement_context_shares_fuel_across_committability_searches },
  { name = 'test_cyclic_committability_judgement_reports_budget', fn = test_cyclic_committability_judgement_reports_budget },
  { name = 'test_product_lane_access_reads_base_but_writes_delta', fn = test_product_lane_access_reads_base_but_writes_delta },
  { name = 'test_product_lane_wrap_transforms_after_commit', fn = test_product_lane_wrap_transforms_after_commit },
  { name = 'test_product_lane_wrap_can_perform_after_commit', fn = test_product_lane_wrap_can_perform_after_commit },
  { name = 'test_product_lane_wrap_rejects_transactional_continuation', fn = test_product_lane_wrap_rejects_transactional_continuation },
  { name = 'test_product_lane_and_product_wrap_compose_post_commit', fn = test_product_lane_and_product_wrap_compose_post_commit },
  { name = 'test_world_owns_phase_shaped_evidence_and_resumptions', fn = test_world_owns_phase_shaped_evidence_and_resumptions },
  { name = 'test_resource_responses_use_descriptors', fn = test_resource_responses_use_descriptors },
  { name = 'test_occurrence_refs_are_stable_and_prefix_sensitive', fn = test_occurrence_refs_are_stable_and_prefix_sensitive },
  { name = 'test_settlement_selected_and_published_lost_are_commit_interpretation', fn = test_settlement_selected_and_published_lost_are_commit_interpretation },
  { name = 'test_root_attempt_world_evidence_resumption_and_commit_plan', fn = test_root_attempt_world_evidence_resumption_and_commit_plan },
  { name = 'test_commit_plan_revalidates_root_attempt_ownership', fn = test_commit_plan_revalidates_root_attempt_ownership },
  { name = 'test_commit_plan_prepares_settlement_updates_before_apply', fn = test_commit_plan_prepares_settlement_updates_before_apply },
}

local function run_tests()
  for _, test in ipairs(test_cases) do
    test.fn()
  end
  print('tests: addresses, explicit bind/map frames, proof search/phase guards, guarded expansion, with_nack settlement, tensor/all joins, post-commit frames, PreferLink, nested or_else, product evidence, commit search, committable preference judgements, fragment views, evidence certificates, descriptor responses, settlement algebra, clean architecture objects, root attempt hardening, prepared settlement updates, and product boundary programs passed')
  print()
end

return { run_tests = run_tests }

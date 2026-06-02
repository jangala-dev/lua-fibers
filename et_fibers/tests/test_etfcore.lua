package.path = './?.lua;../?.lua;./?/init.lua;../?/init.lua;' .. package.path

local core = require('etfcore')
local Op = core.Op
local Runtime = core.Runtime
local JudgementContext = core.JudgementContext
local ProofSearch = core.ProofSearch
local Channel = require('channel')
local Ledger = require('ledger')

local empty_env = core._test.empty_env
local expand_expr = core._test.expand_expr
local expand_top_frame = core._test.expand_top_frame
local ExpansionContext = core._test.ExpansionContext
local PartialProof = core._test.PartialProof
local forced_decisions_for_obligation = core._test.forced_decisions_for_obligation
local committable_search_key = core._test.committable_search_key

local function assert_eq(a, b, message)
  if a ~= b then error((message or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2) end
end


local function test_derivation_addresses_are_stable()
  local ch = Channel.new('addr-stable')
  local operation = Op.tensor({ ch:put('x'), ch:get() })

  local frames1 = expand_expr(operation, empty_env(), ExpansionContext.root('addr-root'))
  local frames2 = expand_expr(operation, empty_env(), ExpansionContext.root('addr-root'))

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

  local frames = expand_expr(op, empty_env(), ExpansionContext.root('explicit-bind-link'))
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

  local frames = expand_expr(op, empty_env(), ExpansionContext.root('explicit-map-link'))
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
      return Op.perform(ch:get())
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

local function test_proof_search_is_tri_valued_and_budgeted()
  local rt = Runtime.new()
  local ch = Channel.new('proof-search-budget')

  local receiver = rt:spawn(function()
    Op.perform(ch:get())
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
    Op.perform(ch:get())
  end, 'generation-receiver')
  drain_runnable(rt)

  local absent = ProofSearch.new(rt, first_proof_for(receiver)):run()
  assert_eq(absent.status, 'absent', 'initial receiver-only search should prove absence')
  local absent_generation = absent.generation

  rt:spawn(function()
    Op.perform(ch:put('x'))
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
    got = Op.perform(Op.tensor({ ch:put('x'), ch:get() }))
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
    Op.perform(Op.all({ ch:put('x'), ch:get() }))
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
      Op.tensor({ internal:put('x'), internal:get() }):and_then(function(results)
        return out:put(results[2][1])
      end)
    )
    assert(ok == true, 'tensor continuation put should return true')
  end, 'tensor-join-root')

  rt:spawn(function()
    received = Op.perform(out:get())
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
      Op.all({ a:get(), b:get() }):and_then(function(results)
        return out:put(results[1][1] .. results[2][1])
      end)
    )
    assert(ok == true, 'all continuation put should return true')
  end, 'all-join-root')

  rt:spawn(function() Op.perform(a:put('A')) end, 'all-sender-a')
  rt:spawn(function() Op.perform(b:put('B')) end, 'all-sender-b')
  rt:spawn(function() received = Op.perform(out:get()) end, 'all-join-receiver')

  rt:run()
  assert_eq(received, 'AB', 'all join should feed continuation after external cuts')
end


local function test_wrap_boundary_transforms_after_commit()
  local rt = Runtime.new()
  local ch = Channel.new('wrap-ch')
  local got
  local ran = false

  rt:spawn(function()
    got = Op.perform(ch:get():wrap(function(x)
      ran = true
      return x .. '!'
    end))
  end, 'wrap-receiver')

  rt:spawn(function()
    Op.perform(ch:put('x'))
  end, 'wrap-sender')

  rt:run()
  assert(ran == true, 'wrap boundary should run after commit')
  assert_eq(got, 'x!', 'wrap should transform resumed value')
end

local function test_wrap_boundary_rejects_transactional_continuation()
  local ch = Channel.new('wrap-reject')
  local ok, err = pcall(function()
    return ch:get():wrap(function(x) return x end):and_then(function(x)
      return Op.always(x)
    end)
  end)
  assert(ok == false, 'wrap:and_then should be rejected')
  assert(tostring(err):match('wrap boundary'), 'expected wrap boundary error, got ' .. tostring(err))

  ok, err = pcall(function()
    return ch:get():wrap(function(x) return x end):map(function(x) return x end)
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
      ch:get():wrap(function(x)
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
    got = Op.perform(ch:get():wrap(function(x)
      local ok = Op.perform(out:put(x .. '!'))
      assert(ok == true, 'post-commit wrapper put should complete')
      return x .. '?'
    end))
  end, 'wrap-performing-root')

  rt:spawn(function()
    Op.perform(ch:put('x'))
  end, 'wrap-performing-sender')

  rt:spawn(function()
    observed = Op.perform(out:get())
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
      ch:get():and_then(function(x)
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

  rt:spawn(function() Op.perform(ch:put('x')) end, 'wrap-order-sender')
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
      return Op.perform(ch:get())
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
    local got = Op.perform(ch:get():wrap(function(x)
      saw_post_commit_before = core._test.current_task() and core._test.current_task().phase == 'post_commit'
      local ok = Op.perform(out:put(x .. '!'))
      assert(ok == true, 'post-commit phase nested put should complete')
      saw_post_commit_after = core._test.current_task() and core._test.current_task().phase == 'post_commit'
      return x .. '?'
    end))
    assert_eq(got, 'x?', 'post-commit phase wrapper value')
  end, 'post-commit-phase-root')

  rt:spawn(function() Op.perform(ch:put('x')) end, 'post-commit-phase-sender')
  rt:spawn(function() observed = Op.perform(out:get()) end, 'post-commit-phase-observer')
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
    got = Op.perform(ch:get():or_else(Op.always('fallback')))
  end, 'prefer-fallback-root')

  rt:run()
  assert_eq(got, 'fallback', 'or_else fallback should commit after primary absence is proved')
end

local function test_or_else_primary_rendezvous_beats_fallback()
  local rt = Runtime.new()
  local ch = Channel.new('prefer-primary-rendezvous')
  local got

  rt:spawn(function()
    got = Op.perform(ch:get():or_else(Op.always('fallback')))
  end, 'prefer-receiver')

  rt:spawn(function()
    Op.perform(ch:put('primary-value'))
  end, 'prefer-sender')

  rt:run()
  assert_eq(got, 'primary-value', 'available primary rendezvous should beat fallback')
end

local function test_or_else_fallback_absence_can_report_budget()
  local rt = Runtime.new()
  local ch = Channel.new('prefer-budget')

  local receiver = rt:spawn(function()
    Op.perform(ch:get():or_else(Op.always('fallback')))
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
  local operation = ch:get():or_else(Op.always('fallback'))
  local frames1 = expand_expr(operation, empty_env(), ExpansionContext.root('prefer-address-root'))
  local frames2 = expand_expr(operation, empty_env(), ExpansionContext.root('prefer-address-root'))
  local site1, site2
  for _, f in ipairs(frames1) do
    if f.env and f.env.obligations and f.env.obligations[1] then site1 = f.env.obligations[1].site end
  end
  for _, f in ipairs(frames2) do
    if f.env and f.env.obligations and f.env.obligations[1] then site2 = f.env.obligations[1].site end
  end
  assert(site1 and site2, 'fallback branch should expose preference obligation site')
  assert_eq(site1, site2, 'PreferLink site address should be replay-stable')
end


local function nested_or_else_op(outer, inner)
  return outer:get():or_else(
    inner:get():or_else(Op.always('fallback'))
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
    Op.perform(inner:put('inner-primary'))
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
    Op.perform(outer:put('outer-primary'))
  end, 'nested-outer-sender')

  rt:run()
  assert_eq(got, 'outer-primary', 'outer primary should dominate nested fallback world')
end


local function test_product_base_env_not_duplicated()
  local rt = Runtime.new()
  local ch = Channel.new('product-base-no-dup')

  local operation = ch:get():or_else(Op.always('fallback')):and_then(function()
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
    a:get():or_else(Op.always('fa')),
    b:get():or_else(Op.always('fb')),
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

  assert_eq(observed[1][1], 1, 'product lane access should read base_env + local delta')
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
      a:get():wrap(function(x)
        ran = true
        return x .. '!'
      end),
      b:get(),
    }))
  end, 'lane-wrap-root')

  rt:spawn(function() Op.perform(a:put('A')) end, 'lane-wrap-sender-a')
  rt:spawn(function() Op.perform(b:put('B')) end, 'lane-wrap-sender-b')
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
      a:get():wrap(function(x)
        local y = Op.perform(c:get())
        return x .. y
      end),
      b:get(),
    }))
  end, 'lane-wrap-performing-root')

  rt:spawn(function() Op.perform(a:put('A')) end, 'lane-wrap-performing-sender-a')
  rt:spawn(function() Op.perform(b:put('B')) end, 'lane-wrap-performing-sender-b')
  rt:spawn(function() Op.perform(c:put('C')) end, 'lane-wrap-performing-sender-c')
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

local function run_tests()
  test_derivation_addresses_are_stable()
  test_bind_link_is_explicit_and_reduced_by_search()
  test_map_link_is_explicit_and_reduced_by_search()
  test_map_is_transactional_before_commit_and_wrap_after_commit()
  test_map_callback_cannot_perform()
  test_bind_callback_must_return_op()
  test_proof_search_is_tri_valued_and_budgeted()
  test_absence_is_generation_stable_not_timeless()
  test_search_phase_forbids_perform_and_spawn()
  test_tensor_self_rendezvous_succeeds()
  test_all_self_rendezvous_fails()
  test_tensor_join_feeds_transactional_continuation()
  test_all_join_feeds_transactional_continuation_after_external_cuts()
  test_wrap_boundary_transforms_after_commit()
  test_wrap_boundary_rejects_transactional_continuation()
  test_wrap_boundary_is_branch_local()
  test_wrap_boundary_can_perform_after_commit()
  test_wrap_boundary_after_commit_event_order()
  test_post_commit_phase_is_explicit_in_wrapper()
  test_or_else_primary_done_wins()
  test_or_else_fallback_commits_after_absence_proof()
  test_or_else_primary_rendezvous_beats_fallback()
  test_or_else_fallback_absence_can_report_budget()
  test_or_else_site_address_is_replay_stable()
  test_nested_or_else_obligation_prefixes()
  test_forced_decisions_for_nested_obligation()
  test_nested_or_else_inner_primary_under_outer_fallback()
  test_nested_or_else_outer_primary_dominates_inner_fallback()
  test_product_base_env_not_duplicated()
  test_product_lane_obligations_are_lane_local()
  test_search_committable_task_skips_rejected_candidate()
  test_preference_obligation_looks_for_committable_not_merely_valid()
  test_preference_obligation_continues_to_later_committable_preferred_world()
  test_judgement_context_shares_fuel_across_committability_searches()
  test_cyclic_committability_judgement_reports_budget()
  test_product_lane_access_reads_base_but_writes_delta()
  test_product_lane_wrap_transforms_after_commit()
  test_product_lane_wrap_can_perform_after_commit()
  test_product_lane_wrap_rejects_transactional_continuation()
  test_product_lane_and_product_wrap_compose_post_commit()
  print('tests: addresses, explicit bind/map frames, proof search/phase guards, tensor/all joins, post-commit frames, PreferLink, nested or_else, product envs, commit search, committable preference judgements, fragment views, and product boundary programs passed')
  print()
end

return { run_tests = run_tests }

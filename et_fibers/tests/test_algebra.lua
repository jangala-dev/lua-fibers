package.path = './?.lua;../?.lua;./?/init.lua;../?/init.lua;' .. package.path

local core = require('etfcore')
local Op = core.Op
local Runtime = require('runtime').Runtime
local Channel = require('resources.channel')
local Ledger = require('ledger')

local test_api = core._test
local EvidenceDelta = test_api.EvidenceDelta
local ExpansionContext = test_api.ExpansionContext
local RootAttempt = test_api.RootAttempt
local expand_expr = test_api.expand_expr

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual), 2)
  end
end

local function assert_match(text, pattern, message)
  if not tostring(text):match(pattern) then
    error((message or 'assert_match failed') .. ': expected ' .. tostring(text) .. ' to match ' .. tostring(pattern), 2)
  end
end

local function drain_runnable(rt)
  while #rt.runnable > 0 do
    local task = table.remove(rt.runnable, 1)
    rt:resume_task(task)
  end
end

local function run_capture_events(fn)
  local events = {}
  test_api.set_print_event(function(event)
    events[#events + 1] = event
  end)
  local result = { pcall(fn, events) }
  test_api.reset_print_event()
  return result[1], result[2], events
end

local function event_tags(events)
  local tags = {}
  for i = 1, #events do tags[#tags + 1] = events[i].tag end
  return table.concat(tags, ',')
end

local function first_settlement_cell(rt)
  for _, cell in pairs(rt.settlements or {}) do return cell end
  return nil
end

-- A tiny adversarial local transactional resource. It can construct a proof
-- fragment that later fails validation. That is useful for checking that a
-- syntactically closed world is not treated as committable and that failed
-- validation has no partial commit effect.
local ProbeResource = {}
ProbeResource.__index = ProbeResource

function ProbeResource.new(value)
  return setmetatable({ value = value or 0, commits = 0, prepared = 0 }, ProbeResource)
end

function ProbeResource:ok(delta)
  return Op.access(self, { tag = 'ok', delta = delta or 1 })
end

function ProbeResource:bad(delta)
  return Op.access(self, { tag = 'bad', delta = delta or 1 })
end

function ProbeResource:empty_fragment()
  return { delta = 0, bad = false }
end

function ProbeResource:step_fragment(fragment, request)
  local next_fragment = {
    delta = (fragment.delta or 0),
    bad = fragment.bad or false,
  }

  if request.tag == 'ok' then
    next_fragment.delta = next_fragment.delta + (request.delta or 0)
    return true, { value = next_fragment.delta }, next_fragment
  elseif request.tag == 'bad' then
    next_fragment.delta = next_fragment.delta + (request.delta or 0)
    next_fragment.bad = true
    return true, { value = next_fragment.delta }, next_fragment
  end

  return false, 'unknown probe request'
end

function ProbeResource:merge_fragments(a, b)
  return true, {
    delta = (a.delta or 0) + (b.delta or 0),
    bad = (a.bad or false) or (b.bad or false),
  }
end

function ProbeResource:validate_fragment(fragment)
  if fragment.bad then return false, 'probe fragment deliberately invalid' end
  return true
end

function ProbeResource:prepare_commit_fragment(fragment, commit)
  self.prepared = self.prepared + 1
  commit:emit({ tag = 'probe.commit', delta = fragment.delta or 0 })
end

function ProbeResource:commit_fragment(fragment)
  self.commits = self.commits + 1
  self.value = self.value + (fragment.delta or 0)
end

local cases = {}

local function add(name, fn)
  cases[#cases + 1] = { name = name, fn = fn }
end

add('construction_is_inert_for_delayed_operators', function()
  local guard_called = 0
  local nack_called = 0
  local fallback_called = 0

  local op = Op.choice(
    Op.guard(function()
      guard_called = guard_called + 1
      return Op.always('guarded')
    end),
    Op.with_nack(function(nack)
      nack_called = nack_called + 1
      return nack:or_else(Op.always('protected-fallback'))
    end),
    Op.never():or_else(function()
      fallback_called = fallback_called + 1
      return Op.always('fallback')
    end)
  )

  assert_eq(guard_called, 0, 'guard callback should not run at construction')
  assert_eq(nack_called, 0, 'with_nack callback should not run at construction')
  assert_eq(fallback_called, 0, 'function fallback should not run at construction')
  assert(op, 'operation should be constructible')
end)

add('always_map_bind_left_identity_and_wrap_boundary_order', function()
  local rt = Runtime.new()
  local order = {}
  local got

  local ok, err, events = run_capture_events(function()
    rt:spawn(function()
      got = Op.perform(
        Op.always('x')
          :map(function(v)
            order[#order + 1] = 'map'
            return v .. 'm'
          end)
          :and_then(function(v)
            order[#order + 1] = 'bind'
            return Op.emit({ tag = 'algebra.commit' }):and_then(function()
              return Op.always(v .. 'b')
            end)
          end)
          :wrap(function(v)
            order[#order + 1] = 'wrap'
            return v .. 'w'
          end)
      )
    end, 'algebra-map-bind-wrap')
    rt:run()
  end)

  assert(ok, err)
  assert_eq(got, 'xmbw', 'raw map/bind value should feed wrap return value')
  assert_eq(table.concat(order, ','), 'map,bind,wrap', 'map/bind should precede post-commit wrap')
  assert_eq(event_tags(events), 'algebra.commit', 'commit descriptor should be emitted once')
end)

add('choice_discards_losing_world_descriptors_and_wraps', function()
  local rt = Runtime.new()
  local got
  local wraps = {}

  local winner = Op.emit({ tag = 'choice.winner' }):and_then(function()
    return Op.always('winner'):wrap(function(v)
      wraps[#wraps + 1] = 'winner'
      return v
    end)
  end)

  local loser = Op.emit({ tag = 'choice.loser' }):and_then(function()
    return Op.always('loser'):wrap(function(v)
      wraps[#wraps + 1] = 'loser'
      return v
    end)
  end)

  local ok, err, events = run_capture_events(function()
    rt:spawn(function()
      got = Op.perform(Op.choice(winner, loser))
    end, 'algebra-choice')
    rt:run()
  end)

  assert(ok, err)
  assert_eq(got, 'winner', 'first committable choice branch should commit in this deterministic frontier')
  assert_eq(event_tags(events), 'choice.winner', 'losing branch descriptor must be discarded')
  assert_eq(table.concat(wraps, ','), 'winner', 'losing branch wrap must not run')
end)

add('or_else_suppresses_fallback_effects_when_primary_committable', function()
  local rt = Runtime.new()
  local got
  local fallback_built = 0

  local primary = Op.emit({ tag = 'prefer.primary' }):and_then(function()
    return Op.always('primary')
  end)

  local ok, err, events = run_capture_events(function()
    rt:spawn(function()
      got = Op.perform(primary:or_else(function()
        fallback_built = fallback_built + 1
        return Op.emit({ tag = 'prefer.fallback' }):and_then(function()
          return Op.always('fallback')
        end)
      end))
    end, 'algebra-prefer-primary')
    rt:run()
  end)

  assert(ok, err)
  assert_eq(got, 'primary', 'primary should dominate fallback')
  assert_eq(event_tags(events), 'prefer.primary', 'fallback descriptor must not be emitted')
  assert(fallback_built <= 1, 'fallback constructor may be explored but should be replay-stable')
end)

add('or_else_rejects_valid_but_uncommittable_primary_without_partial_commit', function()
  local rt = Runtime.new()
  local probe = ProbeResource.new(10)
  local got

  local ok, err, events = run_capture_events(function()
    rt:spawn(function()
      got = Op.perform(
        probe:bad(5):and_then(function()
          return Op.always('bad-primary')
        end):or_else(Op.always('fallback'))
      )
    end, 'algebra-prefer-invalid-primary')
    rt:run()
  end)

  assert(ok, err)
  assert_eq(got, 'fallback', 'fallback should commit when primary proof is not committable')
  assert_eq(probe.value, 10, 'invalid primary must not mutate resource state')
  assert_eq(probe.commits, 0, 'invalid primary commit_fragment must not run')
  assert_eq(event_tags(events), '', 'invalid primary prepare descriptors must not be emitted')
end)

add('guard_replay_is_attempt_local_not_search_replay_local', function()
  local called = 0
  local op = Op.guard(function()
    called = called + 1
    return Op.always('guard-' .. tostring(called))
  end)

  local task = { id = 7001, parked = true, name = 'guard-algebra-task' }
  local attempt1 = RootAttempt.new(task, op, 1, 1)
  task.attempt = attempt1
  task.attempt_id = attempt1.id

  local ctx1 = ExpansionContext.root('guard-algebra-root', task, nil, attempt1)
  local f1 = expand_expr(op, EvidenceDelta.empty(), ctx1)
  local f2 = expand_expr(op, EvidenceDelta.empty(), ctx1)

  assert_eq(called, 1, 'guard should be memoized during proof replay of one attempt')
  assert_eq(f1[1].values[1], 'guard-1', 'first replay should see first guarded op')
  assert_eq(f2[1].values[1], 'guard-1', 'second replay should reuse guarded op')

  local attempt2 = RootAttempt.new(task, op, 2, 2)
  task.attempt = attempt2
  task.attempt_id = attempt2.id
  local f3 = expand_expr(op, EvidenceDelta.empty(), ExpansionContext.root('guard-algebra-root', task, nil, attempt2))

  assert_eq(called, 2, 'new attempt should get a fresh guard expansion')
  assert_eq(f3[1].values[1], 'guard-2', 'fresh attempt should see fresh guarded op')
end)

add('request_rendezvous_and_local_access_commit_as_one_world', function()
  local rt = Runtime.new()
  local ch = Channel.new('algebra-rendezvous-access')
  local probe = ProbeResource.new(0)
  local receiver_got

  local ok, err, events = run_capture_events(function()
    rt:spawn(function()
      Op.perform(ch:put_op('msg'):and_then(function()
        return probe:ok(3)
      end))
    end, 'algebra-sender-access')

    rt:spawn(function()
      receiver_got = Op.perform(ch:get_op())
    end, 'algebra-receiver')

    rt:run()
  end)

  assert(ok, err)
  assert_eq(receiver_got, 'msg', 'rendezvous receiver should observe sender value')
  assert_eq(probe.value, 3, 'local resource update should commit with rendezvous')
  assert_eq(probe.commits, 1, 'resource commit_fragment should run once')
  assert_eq(event_tags(events), 'probe.commit', 'resource descriptor should be emitted once after prepare')
end)

add('tensor_all_topology_is_enforced_adversarially', function()
  local rt = Runtime.new()
  local tensor_ch = Channel.new('algebra-tensor-self')
  local tensor_got

  rt:spawn(function()
    tensor_got = Op.perform(Op.tensor({ tensor_ch:put_op('x'), tensor_ch:get_op() }))
  end, 'algebra-tensor-self-root')

  rt:run()
  assert(type(tensor_got) == 'table', 'tensor should return a product table')
  assert_eq(tensor_got[1][1], true, 'tensor put lane should receive put acknowledgement')
  assert_eq(tensor_got[2][1], 'x', 'tensor get lane should receive put value')

  rt = Runtime.new()
  rt.quiet_deadlock = true
  local all_ch = Channel.new('algebra-all-self')
  local all_done = false
  rt:spawn(function()
    Op.perform(Op.all({ all_ch:put_op('x'), all_ch:get_op() }))
    all_done = true
  end, 'algebra-all-self-root')

  local ok = pcall(function() rt:run() end)
  assert(ok == false, 'all must not allow internal self-rendezvous')
  assert_eq(all_done, false, 'all self-rendezvous should remain uncommitted')
end)

add('post_commit_failure_cannot_rollback_committed_resources_or_descriptors', function()
  local rt = Runtime.new()
  local ledger = Ledger.new({ r = 'A' })

  local ok, err, events = run_capture_events(function()
    rt:spawn(function()
      Op.perform(ledger:move_op('r', 'A', 'B'):wrap(function()
        error('post-commit failure')
      end))
    end, 'algebra-wrap-failure-root')
    rt:run()
  end)

  assert(ok == false, 'wrap failure should escape as ordinary post-commit failure')
  assert_match(err, 'post%-commit failure', 'expected post-commit error')
  assert_eq(ledger.owners.r, 'B', 'committed resource state must not roll back after wrap failure')
  assert(event_tags(events):match('ledger%.move'), 'ledger.move descriptor should have been emitted before wrap failure')
end)

add('with_nack_lost_is_resolved_attempt_nonselection_not_global_nonselection', function()
  local rt = Runtime.new()
  rt.quiet_deadlock = true
  local pending_ch = Channel.new('algebra-pending-nack')
  local other_ch = Channel.new('algebra-other-commit')
  local saved_nack
  local other_got

  rt:spawn(function()
    Op.perform(Op.with_nack(function(nack)
      saved_nack = nack
      return pending_ch:get_op()
    end))
  end, 'algebra-pending-nack-root')

  rt:spawn(function()
    Op.perform(other_ch:put_op('other'))
  end, 'algebra-other-put')

  rt:spawn(function()
    other_got = Op.perform(other_ch:get_op())
  end, 'algebra-other-get')

  drain_runnable(rt)
  assert(saved_nack, 'with_nack should have been expanded in retained frontier')
  assert_eq(rt:try_commit_one(), 'committed', 'unrelated rendezvous should commit')
  drain_runnable(rt)
  assert_eq(other_got, 'other', 'unrelated transaction should complete')

  local cell = rt:settlement_cell(saved_nack.settlement)
  assert_eq(cell.state, 'pending', 'unrelated commit must not settle published nack lost')
  assert_eq(cell.published, true, 'protected pending nack should remain published')
end)

add('with_nack_same_world_circularity_and_later_loss_are_distinct', function()
  local rt = Runtime.new()
  rt.quiet_deadlock = true
  local circular_done = false

  rt:spawn(function()
    Op.perform(Op.with_nack(function(nack)
      return Op.never():or_else(nack)
    end))
    circular_done = true
  end, 'algebra-circular-nack')

  local ok = pcall(function() rt:run() end)
  assert(ok == false, 'nack must not observe loss produced by the same plan')
  assert_eq(circular_done, false, 'same-world circular nack should not commit')

  rt = Runtime.new()
  rt.quiet_deadlock = true
  local ch = Channel.new('algebra-nack-lost-later')
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
  end, 'algebra-nack-lost-root')

  rt:run()
  assert_eq(got, 'fallback', 'fallback should resolve root attempt')
  local cell = rt:settlement_cell(saved_nack.settlement)
  assert_eq(cell.state, 'lost', 'published protected alternative should settle lost after resolved nonselection')

  local nack_closed = false
  rt:spawn(function()
    Op.perform(saved_nack)
    nack_closed = true
  end, 'algebra-lost-nack-close')
  rt:run()
  assert_eq(nack_closed, true, 'nack should close in a later plan after prior loss')
end)

add('with_nack_selection_in_product_publishes_and_settles_product_occurrence', function()
  local rt = Runtime.new()
  local saved_nack
  local got

  rt:spawn(function()
    got = Op.perform(Op.tensor({
      Op.with_nack(function(nack)
        saved_nack = nack
        return Op.always('protected')
      end),
      Op.always('other'),
    }))
  end, 'algebra-product-nack-selected')

  rt:run()
  assert(type(got) == 'table', 'tensor result should be a table')
  assert_eq(got[1][1], 'protected', 'protected lane should return its value')
  assert_eq(got[2][1], 'other', 'other lane should return its value')
  local cell = rt:settlement_cell(saved_nack.settlement)
  assert_eq(cell.state, 'selected', 'product-protected occurrence should settle selected')
  assert_eq(cell.published, true, 'product-protected occurrence should be published from retained frontier')
end)

add('proof_construction_callbacks_cannot_perform_or_spawn', function()
  local function expect_proof_error(op_factory, label)
    local rt = Runtime.new()
    rt.quiet_deadlock = true
    local ch = Channel.new('algebra-proof-error-' .. label)
    rt:spawn(function()
      Op.perform(op_factory(rt, ch))
    end, 'algebra-proof-error-' .. label)

    local ok, err = pcall(function() drain_runnable(rt) end)
    if ok then
      ok, err = pcall(function() rt:try_commit_one() end)
    end
    assert(ok == false, label .. ' should fail during proof construction')
    assert_match(err, 'proof search', label .. ' should report proof search phase')
  end

  expect_proof_error(function(_, ch)
    return Op.guard(function()
      return Op.perform(ch:get_op())
    end)
  end, 'guard-perform')

  expect_proof_error(function(rt, _)
    return Op.with_nack(function()
      rt:spawn(function() end, 'bad-spawn')
      return Op.always('x')
    end)
  end, 'with-nack-spawn')

  expect_proof_error(function(_, ch)
    return Op.always('x'):and_then(function()
      return Op.perform(ch:get_op())
    end)
  end, 'bind-perform')

  expect_proof_error(function(_, ch)
    return Op.always('x'):map(function()
      return Op.perform(ch:get_op())
    end)
  end, 'map-perform')
end)

add('emit_is_commit_level_not_search_level', function()
  local rt = Runtime.new()
  rt.quiet_deadlock = true
  local ch = Channel.new('algebra-emit-open')

  local ok, err = run_capture_events(function(events)
    rt:spawn(function()
      Op.perform(ch:get_op():and_then(function()
        return Op.emit({ tag = 'should-not-emit-before-cut' })
      end))
    end, 'algebra-open-emit-root')

    drain_runnable(rt)
    assert_eq(#events, 0, 'open proof search must not emit descriptors')
    local status = rt:try_commit_one()
    assert_eq(status, 'blocked', 'open receive should not commit without sender')
    assert_eq(#events, 0, 'blocked proof must still not emit descriptors')
  end)

  assert(ok, err)
end)



add('invalid_candidate_must_not_publish_or_settle_speculative_with_nack', function()
  local rt = Runtime.new()
  local probe = ProbeResource.new(0)
  local saved_nack
  local got

  rt:spawn(function()
    got = Op.perform(
      probe:bad(1):and_then(function()
        return Op.with_nack(function(nack)
          saved_nack = nack
          return Op.always('bad-protected')
        end)
      end):or_else(Op.always('fallback'))
    )
  end, 'algebra-speculative-nack-invalid-primary')

  rt:run()
  assert_eq(got, 'fallback', 'fallback should commit after invalid primary candidate')
  assert(saved_nack, 'speculative with_nack may be constructed during candidate proof')

  local cell = rt.settlements and rt.settlements[saved_nack.settlement.key]
  assert(cell == nil or cell.published == false,
    'speculative with_nack from invalid candidate must not be published')
  assert(cell == nil or cell.state == 'pending',
    'speculative with_nack from invalid candidate must not be terminally settled')
end)

add('losing_choice_branch_must_not_leak_resource_descriptor_or_wrap_but_published_nack_may_lose', function()
  local rt = Runtime.new()
  local probe = ProbeResource.new(0)
  local saved_nack
  local wraps = {}
  local got

  local winner = Op.always('winner')

  local loser = Op.with_nack(function(nack)
    saved_nack = nack
    return probe:ok(9):and_then(function()
      return Op.emit({ tag = 'loser.emit' }):and_then(function()
        return Op.always('loser'):wrap(function(v)
          wraps[#wraps + 1] = 'loser-wrap'
          return v
        end)
      end)
    end)
  end)

  local ok, err, events = run_capture_events(function()
    rt:spawn(function()
      got = Op.perform(Op.choice(winner, loser))
    end, 'algebra-losing-branch-no-leak')
    rt:run()
  end)

  assert(ok, err)
  assert_eq(got, 'winner', 'winner should commit')
  assert_eq(probe.value, 0, 'losing branch local resource must not commit')
  assert_eq(probe.commits, 0, 'losing branch commit_fragment must not run')
  assert_eq(event_tags(events), '', 'losing branch commit descriptor must not emit')
  assert_eq(table.concat(wraps, ','), '', 'losing branch wrap must not run')
  assert(saved_nack, 'losing protected branch should have been published from retained choice frontier')
  assert_eq(rt:settlement_cell(saved_nack.settlement).state, 'lost',
    'published protected loser should settle lost as part of resolved attempt')
end)

add('validation_failure_of_any_resource_prevents_prepare_commit_and_descriptors_for_all_resources', function()
  local rt = Runtime.new()
  local good = ProbeResource.new(0)
  local bad = ProbeResource.new(0)
  local got

  local ok, err, events = run_capture_events(function()
    rt:spawn(function()
      got = Op.perform(
        Op.all({ good:ok(3), bad:bad(5) })
          :map(function() return 'invalid-product' end)
          :or_else(Op.always('fallback'))
      )
    end, 'algebra-validate-before-prepare')
    rt:run()
  end)

  assert(ok, err)
  assert_eq(got, 'fallback', 'fallback should commit after product validation failure')
  assert_eq(good.value, 0, 'valid fragment in invalid world must not commit')
  assert_eq(bad.value, 0, 'invalid fragment must not commit')
  assert_eq(good.prepared, 0, 'prepare must not run before all fragments validate')
  assert_eq(bad.prepared, 0, 'prepare must not run for invalid world')
  assert_eq(event_tags(events), '', 'prepare-time descriptors from invalid world must not emit')
end)

add('nack_after_prior_loss_closes_inside_all_and_tensor_without_new_settlement', function()
  local rt = Runtime.new()
  rt.quiet_deadlock = true
  local ch = Channel.new('algebra-prior-loss-product-nack')
  local saved_nack

  rt:spawn(function()
    Op.perform(Op.choice(
      Op.with_nack(function(nack)
        saved_nack = nack
        return ch:get_op()
      end),
      Op.always('fallback')
    ))
  end, 'algebra-create-prior-loss-for-product')
  rt:run()

  assert(saved_nack, 'prior lost nack should have been captured')
  assert_eq(rt:settlement_cell(saved_nack.settlement).state, 'lost',
    'setup should settle protected occurrence lost')

  local tensor_got
  rt:spawn(function()
    tensor_got = Op.perform(Op.tensor({ saved_nack, Op.always('side') }))
  end, 'algebra-lost-nack-in-tensor')
  rt:run()
  assert(type(tensor_got) == 'table', 'tensor containing previously-lost nack should commit')
  assert_eq(tensor_got[2][1], 'side', 'tensor side lane should return')

  local all_got
  rt:spawn(function()
    all_got = Op.perform(Op.all({ saved_nack, Op.always('side') }))
  end, 'algebra-lost-nack-in-all')
  rt:run()
  assert(type(all_got) == 'table', 'all containing previously-lost nack should commit')
  assert_eq(all_got[2][1], 'side', 'all side result should return')
  assert_eq(rt:settlement_cell(saved_nack.settlement).state, 'lost',
    'using a nack must observe prior settlement, not resettle it')
end)

add('with_nack_inside_product_losing_branch_loses_only_when_root_attempt_resolves', function()
  local rt = Runtime.new()
  local ch = Channel.new('algebra-product-branch-loss')
  local saved_nack
  local got

  rt:spawn(function()
    got = Op.perform(Op.choice(
      Op.tensor({
        Op.with_nack(function(nack)
          saved_nack = nack
          return ch:get_op()
        end),
        Op.always('lane'),
      }),
      Op.always('fallback')
    ))
  end, 'algebra-product-branch-loss-root')

  rt:run()
  assert_eq(got, 'fallback', 'fallback should resolve root when product branch is open')
  assert(saved_nack, 'protected occurrence inside retained product branch should be captured')
  local cell = rt:settlement_cell(saved_nack.settlement)
  assert_eq(cell.published, true, 'product branch protected occurrence should have been published')
  assert_eq(cell.state, 'lost', 'resolved nonselection of product branch should settle protected occurrence lost')
end)

add('guard_speculation_may_run_but_must_not_emit_or_commit_losing_worlds', function()
  local rt = Runtime.new()
  local probe = ProbeResource.new(0)
  local guard_called = 0
  local got

  local guarded_loser = Op.guard(function()
    guard_called = guard_called + 1
    return probe:ok(4):and_then(function()
      return Op.emit({ tag = 'guarded.loser.emit' }):and_then(function()
        return Op.always('guarded-loser')
      end)
    end)
  end)

  local ok, err, events = run_capture_events(function()
    rt:spawn(function()
      got = Op.perform(Op.choice(Op.always('winner'), guarded_loser))
    end, 'algebra-guard-losing-world')
    rt:run()
  end)

  assert(ok, err)
  assert(guard_called <= 1, 'guard loser may be inspected, but must be replay-stable')
  assert_eq(got, 'winner', 'winner should commit')
  assert_eq(probe.value, 0, 'guarded losing resource must not commit')
  assert_eq(event_tags(events), '', 'guarded losing emit must not be interpreted')
end)

add('guarded_all_and_tensor_topology_do_not_converge', function()
  local rt = Runtime.new()
  local tensor_ch = Channel.new('algebra-guarded-tensor-self')
  local tensor_got

  rt:spawn(function()
    tensor_got = Op.perform(Op.tensor({
      Op.guard(function() return tensor_ch:put_op('x') end),
      Op.guard(function() return tensor_ch:get_op() end),
    }))
  end, 'algebra-guarded-tensor-self-root')

  rt:run()
  assert(type(tensor_got) == 'table', 'guarded tensor should return a product table')
  assert_eq(tensor_got[1][1], true, 'guarded tensor put lane should receive put acknowledgement')
  assert_eq(tensor_got[2][1], 'x', 'guarded tensor get lane should receive put value')

  rt = Runtime.new()
  rt.quiet_deadlock = true
  local all_ch = Channel.new('algebra-guarded-all-self')
  local all_done = false

  rt:spawn(function()
    Op.perform(Op.all({
      Op.guard(function() return all_ch:put_op('x') end),
      Op.guard(function() return all_ch:get_op() end),
    }))
    all_done = true
  end, 'algebra-guarded-all-self-root')

  local ok = pcall(function() rt:run() end)
  assert(ok == false, 'guarded all must not allow internal self-rendezvous')
  assert_eq(all_done, false, 'guarded all self-rendezvous should remain uncommitted')
end)

local function run_tests()
  for _, case in ipairs(cases) do
    case.fn()
  end
  print('algebra tests: phase separation, choice discard, preference committability, guarded replay, rendezvous/access atomicity, product topology, post-commit irreversibility, with_nack settlement, proof-construction bans, and commit-level emit passed')
  print()
end

return { run_tests = run_tests }

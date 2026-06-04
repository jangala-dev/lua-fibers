package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

local Result = require('et.machine.kernel').Status
local Phase = require('et.machine.kernel').Phase
local Op = require('et.op')
local Runtime = require('et.runtime')
local Channel = require('et.resources.channel')
local Cell = require('et.resources.cell')
local Link = require('et.protocol').Link
local Util = require('et.machine.kernel').Util
local View = require('et.machine.frontier').View
local Frontier = require('et.machine.frontier').Frontier
local ProofSearch = require('et.machine.proofnet')
local CommitCertificate = require('et.machine.commit').Certificate
local Obligation = require('et.machine.frontier').Obligation

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual), 2)
  end
end

local function assert_status(x, tag, message)
  if not x or x.tag ~= tag then
    error((message or 'status mismatch') .. ': expected ' .. tostring(tag) .. ', got ' .. tostring(x and x.tag), 2)
  end
  return x.value
end

local function event_tags(rt)
  local logs = rt.published_consequences or {}
  local tags = {}
  for i = 1, #logs do
    for j = 1, #(logs[i].transaction or {}) do
      tags[#tags + 1] = logs[i].transaction[j].tag or logs[i].transaction[j].kind
    end
  end
  return table.concat(tags, ',')
end

local function reset()
  if Obligation.reset_for_tests then Obligation.reset_for_tests() end
end

local next_probe = 0
local function copy_probe(f) return { base_version = f.base_version, delta = f.delta or 0, bad = f.bad or false } end

local function probe_merge(self, snap, request, ctx)
  local fragments = request.fragments or {}
  if request.kind == 'project' then
    local base, full = request.base, fragments[1]
    if base.base_version ~= snap.version or full.base_version ~= snap.version then return ctx:stale({ self }, 'probe stale') end
    if base.delta == full.delta and base.bad == full.bad then return nil end
    return { base_version = snap.version, delta = (full.delta or 0) - (base.delta or 0), bad = (full.bad or false) and not (base.bad or false) }
  elseif request.kind == 'extend' then
    local prefix = request.base
    for i=1,#fragments do
      local delta = fragments[i]
      if prefix.base_version ~= snap.version or delta.base_version ~= snap.version then return ctx:stale({ self }, 'probe stale') end
      prefix = { base_version = snap.version, delta = (prefix.delta or 0) + (delta.delta or 0), bad = (prefix.bad or false) or (delta.bad or false) }
    end
    return prefix
  end
  local acc = request.base or { base_version = snap.version, delta = 0, bad = false }
  for i=1,#fragments do
    local right = fragments[i]
    if acc.base_version ~= snap.version or right.base_version ~= snap.version then return ctx:stale({ self }, 'probe stale') end
    acc = { base_version = snap.version, delta = (acc.delta or 0) + (right.delta or 0), bad = (acc.bad or false) or (right.bad or false) }
  end
  return acc
end

local Probe = Link.resource {
  name = 'probe',
  construct = function(self, value)
    next_probe = next_probe + 1
    self.id = 'probe-'..next_probe
    self.value = value or 0
    self.version = 0
    self.commits = 0
    self.prepared = 0
  end,
  snapshot = function(self) return { resource = self, version = self.version, value = self.value } end,
  initial = function(_self, snap) return { base_version = snap.version, delta = 0, bad = false } end,
  claim = function(self, snap, fragment, claim, ctx)
    if fragment.base_version ~= snap.version then return ctx:stale({ self }, 'probe stale') end
    local req = claim.request or claim.payload or claim
    local out = copy_probe(fragment)
    if req.tag == 'ok' then
      out.delta = out.delta + (req.delta or 1)
      return ctx:accept(out, out.delta)
    elseif req.tag == 'bad' then
      out.delta = out.delta + (req.delta or 1)
      out.bad = true
      return ctx:accept(out, out.delta)
    end
    return ctx:fatal('unknown probe request '..tostring(req.tag))
  end,
  merge = probe_merge,
  prepare = function(self, fragment, ctx)
    self.prepared = self.prepared + 1
    if fragment.base_version ~= self.version then return ctx:stale({ self }, 'probe stale') end
    if fragment.bad then return ctx:conflict('probe fragment deliberately invalid') end
    local probe = self
    local delta = fragment.delta or 0
    return ctx:prepared({
      resource = probe,
      dirty = delta ~= 0 and { probe } or {},
      consequences = { transaction = { { tag = 'probe.commit', delta = delta } }, resource = {}, obligation = {} },
      apply = function(token2)
        Phase.require(token2, 'commit')
        probe.commits = probe.commits + 1
        probe.value = probe.value + delta
        if delta ~= 0 then probe.version = probe.version + 1 end
      end,
    })
  end,
}
function Probe:ok_op(delta) return Op.access(self, { tag = 'ok', delta = delta }) end
function Probe:bad_op(delta) return Op.access(self, { tag = 'bad', delta = delta }) end

local function construction_is_inert_for_delayed_operators()
  reset()
  local nack_called = 0
  local op = Op.with_nack(function(nack)
    nack_called = nack_called + 1
    return Op._nack(nack.obligation):or_else(Op.always('protected-fallback'))
  end)
  assert_eq(nack_called, 0, 'with_nack callback should not run at construction')
  assert(op, 'transaction should be constructible')
end

local function always_map_bind_left_identity_and_wrap_boundary_order()
  local rt = Runtime.new()
  local order = {}
  local got
  rt:spawn(function()
    got = rt:perform(
      Op.always('x')
        :map(function(v) order[#order + 1] = 'map'; return v .. 'm' end)
        :and_then(function(v)
          order[#order + 1] = 'bind'
          return Op.emit({ tag = 'algebra.commit' }):and_then(function() return Op.always(v .. 'b') end)
        end)
        :wrap(function(v) order[#order + 1] = 'wrap'; return v .. 'w' end)
    )
  end, 'old-algebra-map-bind-wrap')
  assert_status(rt:run(), 'found')
  assert_eq(got, 'xmbw')
  assert(order[1] == 'map', 'map may replay during proof search but must happen before bind')
  assert(order[#order - 1] == 'bind', 'bind precedes wrap')
  assert(order[#order] == 'wrap', 'wrap is post-commit')
  assert_eq(event_tags(rt), 'algebra.commit')
end

local function choice_discards_losing_world_descriptors_and_wraps()
  local rt = Runtime.new()
  local got
  local wraps = {}
  local winner = Op.emit({ tag = 'choice.winner' }):and_then(function()
    return Op.always('winner'):wrap(function(v) wraps[#wraps + 1] = 'winner'; return v end)
  end)
  local loser = Op.emit({ tag = 'choice.loser' }):and_then(function()
    return Op.always('loser'):wrap(function(v) wraps[#wraps + 1] = 'loser'; return v end)
  end)
  rt:spawn(function() got = rt:perform(Op.choice(winner, loser)) end, 'old-choice')
  assert_status(rt:run(), 'found')
  assert_eq(got, 'winner')
  assert_eq(event_tags(rt), 'choice.winner')
  assert_eq(table.concat(wraps, ','), 'winner')
end

local function or_else_suppresses_fallback_effects_when_primary_committable()
  local rt = Runtime.new()
  local got
  local primary = Op.emit({ tag = 'prefer.primary' }):and_then(function() return Op.always('primary') end)
  rt:spawn(function()
    got = rt:perform(primary:or_else(Op.emit({ tag = 'prefer.fallback' }):and_then(function() return Op.always('fallback') end)))
  end, 'old-prefer-primary')
  assert_status(rt:run(), 'found')
  assert_eq(got, 'primary')
  assert_eq(event_tags(rt), 'prefer.primary')
end

local function or_else_rejects_valid_but_uncommittable_primary_without_partial_commit()
  local rt = Runtime.new()
  local probe = Probe.new(10)
  local got
  rt:spawn(function()
    got = rt:perform(probe:bad_op(5):and_then(function() return Op.always('bad-primary') end):or_else(Op.always('fallback')))
  end, 'old-invalid-primary')
  assert_status(rt:run(), 'found')
  assert_eq(got, 'fallback')
  assert_eq(probe.value, 10, 'invalid primary must not mutate resource')
  assert_eq(probe.commits, 0, 'invalid primary must not commit')
end

local function request_claim_completion_and_local_access_commit_as_one_world()
  local rt = Runtime.new()
  local ch = Channel.new('old-claim_completion-access')
  local probe = Probe.new(0)
  local got_recv
  rt:spawn(function()
    rt:perform(ch:put_op(Op, 'payload'):and_then(function()
      return probe:ok_op(3)
    end))
  end, 'old-send-access')
  rt:spawn(function()
    got_recv = rt:perform(ch:get_op(Op))
  end, 'old-recv-access')
  assert_status(rt:run(), 'found')
  assert_eq(got_recv, 'payload')
  assert_eq(probe.value, 3, 'local resource update should commit with claim_completion')
  assert_eq(probe.commits, 1, 'resource commit should run once')
  assert_eq(event_tags(rt), 'probe.commit', 'resource consequence should publish once')
end

local function tensor_all_topology_is_enforced_adversarially()
  do
    local rt = Runtime.new()
    local ch = Channel.new('old-tensor')
    local result
    rt:spawn(function() result = rt:perform(Op.tensor({ ch:put_op(Op, 'x'), ch:get_op(Op) })) end, 'old-tensor')
    assert_status(rt:run(), 'found')
    assert_eq(result[1][1], true)
    assert_eq(result[2][1], 'x')
  end
  do
    local rt = Runtime.new({ quiet_deadlock = true })
    local ch = Channel.new('old-all')
    rt:spawn(function() rt:perform(Op.all({ ch:put_op(Op, 'x'), ch:get_op(Op) })) end, 'old-all')
    assert_eq(rt:run().tag, 'absent')
  end
end

local function post_commit_failure_cannot_rollback_committed_resources_or_consequences()
  local rt = Runtime.new()
  local cell = Cell.new(0, 'old-post-fail-cell')
  rt:spawn(function()
    rt:perform(Op.emit({ tag = 'post.fail.commit' }):and_then(function()
      return cell:set_op(Op, 7):wrap(function() error('post failure') end)
    end))
  end, 'old-post-fail')
  assert_status(rt:run(), 'found')
  assert_eq(cell.value, 7, 'post-commit failure cannot roll back resource commit')
  assert_eq(event_tags(rt), 'post.fail.commit', 'post-commit failure cannot roll back consequence publication')
  assert_eq(rt.tasks[1].state, 'failed', 'participant may fail after commit boundary')
end

local function emit_is_commit_level_not_search_level()
  local rt = Runtime.new({ quiet_deadlock = true })
  local ch = Channel.new('old-emit-search')
  rt:spawn(function()
    rt:perform(Op.emit({ tag = 'emit.waiting' }):and_then(function() return ch:get_op(Op) end))
  end, 'old-emit-waiting')
  local r = rt:run()
  assert_eq(r.tag, 'absent')
  assert_eq(event_tags(rt), '', 'emit in an uncommitted world must not publish')

  local rt2 = Runtime.new()
  local ch2 = Channel.new('old-emit-commit')
  rt2:spawn(function() rt2:perform(Op.emit({ tag = 'emit.committed' }):and_then(function() return ch2:get_op(Op) end)) end, 'old-emit-recv')
  rt2:spawn(function() rt2:perform(ch2:put_op(Op, 'x')) end, 'old-emit-send')
  assert_status(rt2:run(), 'found')
  assert_eq(event_tags(rt2), 'emit.committed')
end

local function validation_failure_of_any_resource_prevents_prepare_commit_and_descriptors_for_all_resources()
  local rt = Runtime.new({ quiet_deadlock = true })
  local good = Probe.new(0)
  local bad = Probe.new(0)
  rt:spawn(function()
    rt:perform(Op.tensor({ good:ok_op(3), bad:bad_op(5) }))
  end, 'old-validation-all-or-none')
  local r = rt:run()
  assert(r.tag == 'absent' or r.tag == 'reject_candidate' or r.tag == 'conflict', 'invalid candidate should not commit; got '..tostring(r.tag))
  assert_eq(good.value, 0, 'good resource must not commit when another selected resource invalidates')
  assert_eq(bad.value, 0, 'bad resource must not commit')
  assert_eq(event_tags(rt), '', 'resource consequences must not publish if certificate fails')
end

local function nack_after_prior_loss_closes_inside_all_and_tensor_without_new_settlement()
  reset()
  local ref_holder
  local rt1 = Runtime.new()
  local ch = Channel.new('old-make-lost')
  rt1:spawn(function()
    rt1:perform(Op.choice(Op.with_nack(function(nack) ref_holder = nack.obligation; return ch:get_op(Op) end), Op.always('winner')))
  end, 'old-make-lost')
  assert_status(rt1:run(), 'found')
  assert_eq(Obligation.state(ref_holder), 'lost')

  local rt2 = Runtime.new()
  local result
  rt2:spawn(function() result = rt2:perform(Op.tensor({ Op._nack(ref_holder), Op.all({ Op.always('ok') }) })) end, 'old-nack-product')
  assert_status(rt2:run(), 'found')
  assert_eq(result[1][1], true)
  assert_eq(result[2][1][1][1], 'ok')
end


local function unrelated_commit_does_not_settle_pending_nack()
  reset()
  local rt = Runtime.new({ quiet_deadlock = true })
  local pending_ch = Channel.new('old-pending-nack')
  local other_ch = Channel.new('old-other-commit')
  local ref_holder
  local other_got

  rt:spawn(function()
    rt:perform(Op.with_nack(function(nack)
      ref_holder = nack.obligation
      return pending_ch:get_op(Op)
    end))
  end, 'old-pending-nack-root')
  rt:spawn(function() rt:perform(other_ch:put_op(Op, 'other')) end, 'old-other-put')
  rt:spawn(function() other_got = rt:perform(other_ch:get_op(Op)) end, 'old-other-get')

  local r = rt:run()
  assert(r.tag == 'absent' or r.tag == 'conflict' or r.tag == 'reject_candidate', 'unrelated commit should complete then leave pending root blocked')
  assert_eq(other_got, 'other')
  assert(ref_holder, 'pending with_nack should have been published')
  assert_eq(Obligation.state(ref_holder), 'pending', 'unrelated commit must not settle pending protected occurrence lost')
end

local function invalid_candidate_must_not_publish_or_settle_speculative_with_nack()
  reset()
  local rt = Runtime.new()
  local probe = Probe.new(0)
  local ref_holder
  local got
  rt:spawn(function()
    got = rt:perform(
      probe:bad_op(1):and_then(function()
        return Op.with_nack(function(nack)
          ref_holder = nack.obligation
          return Op.always('bad-protected')
        end)
      end):or_else(Op.always('fallback'))
    )
  end, 'old-speculative-nack-invalid-primary')
  assert_status(rt:run(), 'found')
  assert_eq(got, 'fallback')
  assert(ref_holder, 'speculative with_nack may be constructed while proving primary')
  assert_eq(Obligation.state(ref_holder), 'unpublished', 'invalid speculative primary must not publish or terminally settle its with_nack')
end

local function losing_choice_branch_must_not_leak_resource_consequence_or_wrap_but_published_nack_may_lose()
  reset()
  local rt = Runtime.new()
  local probe = Probe.new(0)
  local ref_holder
  local wraps = {}
  local got
  local loser = Op.with_nack(function(nack)
    ref_holder = nack.obligation
    return probe:ok_op(9):and_then(function()
      return Op.emit({ tag = 'loser.emit' }):and_then(function()
        return Op.always('loser'):wrap(function(v)
          wraps[#wraps + 1] = 'loser-wrap'
          return v
        end)
      end)
    end)
  end)
  rt:spawn(function() got = rt:perform(Op.choice(Op.always('winner'), loser)) end, 'old-losing-choice')
  assert_status(rt:run(), 'found')
  assert_eq(got, 'winner')
  assert_eq(probe.value, 0, 'losing branch resource must not commit')
  assert_eq(probe.commits, 0, 'losing branch resource apply must not run')
  assert_eq(event_tags(rt), '', 'losing branch explicit/resource consequences must not publish')
  assert_eq(table.concat(wraps, ','), '', 'losing branch wrap must not run')
  assert(ref_holder, 'losing protected branch should have been published from retained choice frontier')
  assert_eq(Obligation.state(ref_holder), 'lost', 'published protected loser settles lost when root resolves')
end

local function with_nack_inside_product_losing_branch_loses_only_when_root_attempt_resolves()
  reset()
  local rt = Runtime.new()
  local ch = Channel.new('old-product-branch-loss')
  local ref_holder
  local got
  rt:spawn(function()
    got = rt:perform(Op.choice(
      Op.tensor({ Op.with_nack(function(nack) ref_holder = nack.obligation; return ch:get_op(Op) end), Op.always('lane') }),
      Op.always('fallback')
    ))
  end, 'old-product-branch-loss')
  assert_status(rt:run(), 'found')
  assert_eq(got, 'fallback')
  assert(ref_holder, 'protected occurrence inside retained product branch should be captured')
  assert_eq(Obligation.state(ref_holder), 'lost', 'resolved nonselection of product branch settles protected occurrence lost')
end

local function proof_construction_callbacks_cannot_perform_or_spawn()
  do
    local rt = Runtime.new()
    local ch = Channel.new('old-proof-perform')
    rt:spawn(function()
      rt:perform(Op.with_nack(function()
        rt:perform(ch:get_op(Op))
        return Op.always('bad')
      end))
    end, 'old-proof-perform')
    local r = rt:run()
    assert_eq(r.tag, 'fatal', 'perform during search/proof construction is fatal')
    assert(tostring(r.reason):match('search phase'), 'perform failure reports search phase')
  end
  do
    local rt = Runtime.new()
    rt:spawn(function()
      rt:perform(Op.with_nack(function()
        rt:spawn(function() end, 'bad-spawn')
        return Op.always('bad')
      end))
    end, 'old-proof-spawn')
    local r = rt:run()
    assert_eq(r.tag, 'fatal', 'spawn during search/proof construction is fatal')
    assert(tostring(r.reason):match('search phase'), 'spawn failure reports search phase')
  end
end

local function boundary_operations_remain_selectable_but_not_transactionally_sequencable()
  local op = Op.always('x'):wrap(function(v) return v .. 'w' end)
  local ok1, err1 = pcall(function() return op:and_then(function() return Op.always('bad') end) end)
  assert_eq(ok1, false, 'cannot bind after wrap boundary')
  assert(tostring(err1):match('sequence after wrap'), 'bind error mentions wrap boundary')
  local ok2, err2 = pcall(function() return op:map(function(v) return v end) end)
  assert_eq(ok2, false, 'cannot map after wrap boundary')
  assert(tostring(err2):match('map after wrap'), 'map error mentions wrap boundary')

  local rt = Runtime.new()
  local got
  rt:spawn(function() got = rt:perform(op) end, 'old-boundary-selectable')
  assert_status(rt:run(), 'found')
  assert_eq(got, 'xw')
end

return function()
  construction_is_inert_for_delayed_operators()
  always_map_bind_left_identity_and_wrap_boundary_order()
  choice_discards_losing_world_descriptors_and_wraps()
  or_else_suppresses_fallback_effects_when_primary_committable()
  or_else_rejects_valid_but_uncommittable_primary_without_partial_commit()
  request_claim_completion_and_local_access_commit_as_one_world()
  tensor_all_topology_is_enforced_adversarially()
  post_commit_failure_cannot_rollback_committed_resources_or_consequences()
  emit_is_commit_level_not_search_level()
  validation_failure_of_any_resource_prevents_prepare_commit_and_descriptors_for_all_resources()
  nack_after_prior_loss_closes_inside_all_and_tensor_without_new_settlement()
  unrelated_commit_does_not_settle_pending_nack()
  invalid_candidate_must_not_publish_or_settle_speculative_with_nack()
  losing_choice_branch_must_not_leak_resource_consequence_or_wrap_but_published_nack_may_lose()
  with_nack_inside_product_losing_branch_loses_only_when_root_attempt_resolves()
  proof_construction_callbacks_cannot_perform_or_spawn()
  boundary_operations_remain_selectable_but_not_transactionally_sequencable()
  print('regression algebra tests: ok')
end

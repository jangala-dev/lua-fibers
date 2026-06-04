package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

local Result = require('et.machine.kernel').Status
local Phase = require('et.machine.kernel').Phase
local Op = require('et.op')
local Runtime = require('et.runtime')
local Channel = require('et.resources.channel')
local Cell = require('et.resources.cell')
local Obligation = require('et.machine.frontier').Obligation
local View = require('et.machine.frontier').View
local Frontier = require('et.machine.frontier').Frontier
local ProofSearch = require('et.machine.proofnet')
local CommitCertificate = require('et.machine.commit').Certificate
local Util = require('et.machine.kernel').Util
local Link = require('et.protocol').Link

local function assert_eq(actual, expected, msg)
  if actual ~= expected then error((msg or 'assert_eq') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual), 2) end
end

local function assert_status(x, tag, msg)
  if not x or x.tag ~= tag then error((msg or 'status') .. ': expected ' .. tostring(tag) .. ', got ' .. tostring(x and x.tag), 2) end
  return x.value
end

local function reset()
  if Obligation.reset_for_tests then Obligation.reset_for_tests() end
end


local BadResource = Link.resource {
  name = 'bad-ms7',
  construct = function(self)
    self.id = 'bad-ms7'
    self.version = 0
  end,
  snapshot = function(self) return { resource = self, version = self.version } end,
  initial = function(_self, snap) return { base_version = snap.version, touched = false } end,
  claim = function(_self, _snap, fragment, _claim, ctx)
    return ctx:accept({ base_version = fragment.base_version, touched = true }, 'bad')
  end,
  merge = function(_self, _snap, request, _ctx)
    local fragments = request.fragments or {}
    if request.kind == 'project' then
      local base, full = request.base, fragments[1]
      if base.touched == full.touched then return nil end
      return full
    end
    return fragments[#fragments] or request.base
  end,
  prepare = function(self, _fragment, ctx) return ctx:conflict('bad resource rejects candidate', self) end,
}
function BadResource:op() return Op.access(self, { tag = 'bad' }) end

local function test_with_nack_does_not_run_callback_at_construction()
  reset()
  local ran = 0
  local op = Op.with_nack(function(_)
    ran = ran + 1
    return Op.always('ok')
  end)
  assert_eq(ran, 0, 'with_nack callback is not construction-time')
  local rt = Runtime.new()
  local got
  rt:spawn(function() got = rt:perform(op) end, 'construction')
  assert_status(rt:run(), 'found')
  assert_eq(ran, 1, 'with_nack callback runs during expansion')
  assert_eq(got, 'ok')
end

local function test_selected_with_nack_commits_selected_obligation_before_publish_resume()
  reset()
  local seen = {}
  local rt = Runtime.new({
    on_consequence = function(log)
      seen[#seen + 1] = { phase = 'consequence', log = log }
    end,
  })
  local observed_state_at_resume
  local ref_id
  rt:spawn(function()
    local op = Op.with_nack(function(nack)
      -- The nack is not used; the protected occurrence is selected.
      return Op.always('protected'):map(function(v)
        return v, nack.obligation.id
      end)
    end)
    local v, id = rt:perform(op)
    ref_id = id
    observed_state_at_resume = Obligation.state({ __et_obligation = true, id = id })
    return v
  end, 'selected')
  assert_status(rt:run(), 'found')
  assert_eq(observed_state_at_resume, 'selected', 'selected obligation state visible before participant continuation completes')
  assert_eq(#seen, 1, 'consequence callback ran once')
  assert_eq(#seen[1].log.obligation, 1, 'selected obligation consequence was published')
  assert_eq(seen[1].log.obligation[1].kind, 'selected')
  assert_eq(seen[1].log.obligation[1].id, ref_id)
end

local function test_published_unselected_with_nack_becomes_lost_when_attempt_resolves_elsewhere()
  reset()
  local rt = Runtime.new()
  local selected_ref_id
  local lost_ref_id
  local got
  local bad = BadResource.new()
  local op = Op.choice(
    Op.with_nack(function(nack)
      lost_ref_id = nack.obligation.id
      return bad:op()
    end),
    Op.with_nack(function(nack)
      selected_ref_id = nack.obligation.id
      return Op.always('winner')
    end)
  )
  rt:spawn(function() got = rt:perform(op) end, 'lost')
  assert_status(rt:run(), 'found')
  assert_eq(got, 'winner')
  assert_eq(Obligation.state({ __et_obligation = true, id = selected_ref_id }), 'selected', 'winner obligation selected')
  assert_eq(Obligation.state({ __et_obligation = true, id = lost_ref_id }), 'lost', 'published unselected obligation lost')
end

local function test_nack_observes_prior_lost_only()
  reset()
  local ref_holder
  local bad = BadResource.new()
  local op = Op.choice(
    Op.with_nack(function(nack)
      ref_holder = nack.obligation
      return bad:op()
    end),
    Op.always('resolve')
  )
  local rt1 = Runtime.new()
  local got1
  rt1:spawn(function() got1 = rt1:perform(op) end, 'make-lost')
  assert_status(rt1:run(), 'found')
  assert_eq(got1, 'resolve')
  assert_eq(Obligation.state(ref_holder), 'lost')

  local rt2 = Runtime.new()
  local got2
  rt2:spawn(function() got2 = rt2:perform(Op._nack(ref_holder)) end, 'observe-lost')
  assert_status(rt2:run(), 'found')
  assert_eq(got2, true, 'nack closes once settlement is prior-lost')
end

local function test_nack_does_not_close_in_same_commit_that_would_make_occurrence_lost()
  reset()
  local got
  local rt = Runtime.new({ quiet_deadlock = true })
  local op = Op.with_nack(function(nack)
    return Op.never():or_else(nack)
  end)
  rt:spawn(function() got = rt:perform(op) end, 'same-plan')
  local r = rt:run()
  assert(r.tag == 'absent' or r.tag == 'conflict' or r.tag == 'reject_candidate', 'same-plan nack must not commit; got '..tostring(r.tag))
  assert_eq(got, nil)
end


local function test_withdrawn_attempt_enables_nack_later()
  reset()
  local rt1 = Runtime.new({ quiet_deadlock = true })
  local ref_holder
  local task = rt1:spawn(function()
    return rt1:perform(Op.with_nack(function(nack)
      ref_holder = nack.obligation
      return Op.always('would-commit')
    end))
  end, 'withdraw-source')
  rt1:run_one_runnable()
  assert_eq(task.state, 'waiting', 'task parked before withdrawal')
  assert_status(rt1:withdraw(task), 'found')
  assert_eq(Obligation.state(ref_holder), 'withdrawn', 'published pending ref becomes withdrawn')

  local rt2 = Runtime.new()
  local got
  rt2:spawn(function() got = rt2:perform(Op._nack(ref_holder)) end, 'observe-withdrawn')
  assert_status(rt2:run(), 'found')
  assert_eq(got, true, 'nack closes once settlement is prior-withdrawn')
end


local function test_refresh_does_not_orphan_published_obligations()
  reset()
  local rt = Runtime.new()
  local ch = Channel.new('refresh-orphan')
  local cell = Cell.new(0, 'refresh-orphan-cell')
  local ref_holder
  local got_a, got_b

  local protected = cell:get_op(Op):and_then(function(v)
    if v == 0 then
      return Op.with_nack(function(nack)
        ref_holder = nack.obligation
        return ch:get_op(Op)
      end)
    end
    return Op.always('after')
  end)

  rt:spawn(function() got_a = rt:perform(protected) end, 'refresh-obligation-root')
  rt:spawn(function() got_b = rt:perform(cell:set_op(Op, 1):and_then(function() return Op.always('set') end)) end, 'refresh-trigger')

  assert_status(rt:run(), 'found')
  assert_eq(got_b, 'set')
  assert_eq(got_a, 'after')
  assert(rt.stats.refreshes >= 1, 'first attempt should refresh after cell change')
  assert(ref_holder, 'initial with_nack publication should have happened')
  assert_eq(Obligation.state(ref_holder), 'lost', 'published obligation from earlier frontier is lost when the same attempt resolves unselected')
end

local function test_with_nack_preserves_product_lane_identity()
  reset()
  local ch = Channel.new('nack-lanes')
  local view = View.open('nack-lanes-view')
  local op = Op.tensor({
    Op.with_nack(function(_) return ch:put_op(Op, 'x') end),
    ch:get_op(Op),
  })
  local frontier = assert_status(Frontier.expand_in_search(op, { id = 'nack-lanes-attempt' }, view), 'found')
  local cand = assert_status(Phase.with('search', function(token) return ProofSearch.find(frontier, view, token) end), 'found')
  local found_selected_obligation = false
  for i = 1, #(cand.selected_delta.selected_obligations or {}) do
    local ref = cand.selected_delta.selected_obligations[i]
    if ref.origin and #(ref.origin.lane_path or {}) > 0 then found_selected_obligation = true end
  end
  assert(found_selected_obligation, 'selected obligation keeps product lane identity')
  local cert = assert_status(CommitCertificate.try_build(cand), 'found')
  assert_eq(#cert.consequences.obligation, 1, 'selected obligation consequence present')
end

return function()
  test_with_nack_does_not_run_callback_at_construction()
  test_selected_with_nack_commits_selected_obligation_before_publish_resume()
  test_published_unselected_with_nack_becomes_lost_when_attempt_resolves_elsewhere()
  test_nack_observes_prior_lost_only()
  test_nack_does_not_close_in_same_commit_that_would_make_occurrence_lost()
  test_withdrawn_attempt_enables_nack_later()
  test_refresh_does_not_orphan_published_obligations()
  test_with_nack_preserves_product_lane_identity()
  print('milestone 7 linear obligation/with_nack tests: ok')
end

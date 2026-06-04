package.path = table.concat({
  './?.lua', './?/init.lua', './?/?.lua',
  package.path,
}, ';')

local Result = require('et.machine.kernel').Status
local Op = require('et.op')
local Runtime = require('et.runtime')
local Channel = require('et.resources.channel')
local Cell = require('et.resources.cell')
local Link = require('et.protocol').Link
local View = require('et.machine.frontier').View
local Frontier = require('et.machine.frontier').Frontier
local ProofSearch = require('et.machine.proofnet')
local Phase = require('et.machine.kernel').Phase

local function assert_eq(actual, expected, msg)
  if actual ~= expected then
    error((msg or 'assert_eq failed') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual), 2)
  end
end

local function assert_status(x, tag, msg)
  if not x or x.tag ~= tag then
    error((msg or 'status mismatch') .. ': expected ' .. tostring(tag) .. ', got ' .. tostring(x and x.tag), 2)
  end
  return x.value
end

local function test_open_bind_after_claim_completion_continues_root()
  local rt = Runtime.new()
  local ch = Channel.new('ms6-bind-claim_completion')
  local sent, received
  rt:spawn(function()
    sent = rt:perform(ch:put_op(Op, 'payload'))
  end, 'bind-sender')
  rt:spawn(function()
    received = rt:perform(ch:get_op(Op):and_then(function(x)
      return Op.always(x .. '-bound')
    end))
  end, 'bind-receiver')
  assert_status(rt:run(), 'found')
  assert_eq(sent, true, 'send commits')
  assert_eq(received, 'payload-bound', 'bind continuation runs after match assignment')
end

local function test_open_bind_can_introduce_later_claim_completion()
  local rt = Runtime.new()
  local first = Channel.new('ms6-bind-first')
  local second = Channel.new('ms6-bind-second')
  local s1, s2, result
  rt:spawn(function()
    s1 = rt:perform(first:put_op(Op, 'A'))
  end, 'first-sender')
  rt:spawn(function()
    s2 = rt:perform(second:put_op(Op, 'B'))
  end, 'second-sender')
  rt:spawn(function()
    result = rt:perform(first:get_op(Op):and_then(function(a)
      return second:get_op(Op):map(function(b) return a .. b end)
    end))
  end, 'sequential-receiver')
  assert_status(rt:run(), 'found')
  assert_eq(s1, true, 'first send commits')
  assert_eq(s2, true, 'second send commits')
  assert_eq(result, 'AB', 'continuation-introduced claim_completion commits in same candidate world')
  assert_eq(rt.stats.commits, 1, 'both claim_completion commits are one Eventful Transaction')
end

local function test_match_alternative_rejected_candidate_does_not_reject_other_match()
  local rt = Runtime.new({ quiet_deadlock = true })
  local ch = Channel.new('ms6-match-alternatives')
  local c = Cell.new(0, 'ms6-match-cell')
  local bad_sender, good_sender, receiver

  rt:spawn(function()
    bad_sender = rt:perform(Op.tensor({ ch:put_op(Op, 'bad'), c:set_op(Op, 1) }))
  end, 'bad-sender')
  rt:spawn(function()
    good_sender = rt:perform(ch:put_op(Op, 'good'))
  end, 'good-sender')
  rt:spawn(function()
    receiver = rt:perform(ch:get_op(Op):and_then(function(v)
      if v == 'bad' then
        return c:set_op(Op, 2):map(function() return v end)
      end
      return Op.always(v)
    end))
  end, 'match-receiver')

  local status = rt:run()
  assert_eq(status.tag, 'absent', 'unmatched bad sender remains after good match commits')
  assert_eq(receiver, 'good', 'search tries another match after bad match is rejected by certification')
  assert_eq(good_sender, true, 'good sender commits')
  assert_eq(bad_sender, nil, 'bad conflicting match does not commit')
  assert_eq(c.value, 0, 'rejected bad match does not mutate resource')
  assert_eq(rt.stats.commits, 1, 'one non-conflicting match commits')
end

local function test_no_resource_mutation_without_certificate()
  local RejectingClass = Link.resource {
    name = 'ms6-rejecting',
    construct = function(self)
      self.label = 'ms6-rejecting'; self.value = 0; self.version = 0
    end,
    snapshot = function(self) return { resource = self, version = self.version, value = self.value } end,
    initial = function(_self, snap) return { base_version = snap.version, value = snap.value, written = false } end,
    claim = function(_self, _snap, fragment, _claim, ctx)
      return ctx:accept({ base_version = fragment.base_version, value = 1, written = true }, true)
    end,
    merge = function(_self, _snap, request, _ctx) return (request.fragments or {})[1] or request.base end,
    prepare = function(_self, _fragment, ctx) return ctx:conflict('prepare rejects before certificate exists') end,
  }
  local Rejecting = RejectingClass.new()

  local rt = Runtime.new({ quiet_deadlock = true })
  local result
  rt:spawn(function()
    result = rt:perform(Op.access(Rejecting, { tag = 'set' }))
  end, 'rejecting-resource')
  local status = rt:run()
  assert_eq(status.tag, 'absent', 'candidate rejection leads to no committable world')
  assert_eq(Rejecting.value, 0, 'resource is not mutated without a CommitCertificate')
  assert_eq(result, nil, 'participant is not resumed without a certificate')
end

local function test_cert_apply_is_no_ordinary_failure_boundary()
  local BadApplyClass = Link.resource {
    name = 'ms6-bad-apply',
    construct = function(self)
      self.label = 'ms6-bad-apply'; self.value = 0; self.version = 0
    end,
    snapshot = function(self) return { resource = self, version = self.version, value = self.value } end,
    initial = function(_self, snap) return { base_version = snap.version } end,
    claim = function(_self, _snap, fragment, _claim, ctx) return ctx:accept(fragment, true) end,
    merge = function(_self, _snap, request, _ctx) return (request.fragments or {})[1] or request.base end,
    prepare = function(self, _fragment, ctx)
      return ctx:prepared({
        resource = self,
        dirty = { self },
        consequences = { transaction = {}, resource = {}, obligation = {} },
        apply = function(_token) error('bad apply') end,
      })
    end,
  }
  local BadApply = BadApplyClass.new()

  local rt = Runtime.new()
  local result
  rt:spawn(function()
    result = rt:perform(Op.access(BadApply, { tag = 'go' }))
  end, 'bad-apply')
  local status = rt:run()
  assert_eq(status.tag, 'fatal', 'ordinary apply failure is fatal at certificate boundary')
  assert(tostring(status.reason):match('prepared resource commit raised'), status.reason)
  assert_eq(result, nil, 'participant is not resumed after failed apply')
end

local function test_resource_consequence_precedes_resume()
  local events = {}
  local ConsequentialClass = Link.resource {
    name = 'ms6-consequential',
    construct = function(self)
      self.id = 'ms6-consequential'; self.label = 'ms6-consequential'; self.value = 0; self.version = 0
    end,
    snapshot = function(self) return { resource = self, version = self.version, value = self.value } end,
    initial = function(_self, snap) return { base_version = snap.version, value = snap.value } end,
    claim = function(_self, _snap, fragment, _claim, ctx)
      return ctx:accept({ base_version = fragment.base_version, value = 1 }, true)
    end,
    merge = function(_self, _snap, request, _ctx) return (request.fragments or {})[1] or request.base end,
    prepare = function(self, fragment, ctx)
      local res = self
      return ctx:prepared({
        resource = res,
        dirty = { res },
        consequences = { transaction = {}, resource = { { kind = 'wake', key = res.id } }, obligation = {} },
        apply = function(_token) res.value = fragment.value; res.version = res.version + 1 end,
      })
    end,
  }
  local Consequential = ConsequentialClass.new()

  local rt
  local result
  rt = Runtime.new({ on_consequence = function(log)
    events[#events + 1] = 'publish'
    assert_eq(Consequential.value, 1, 'resource is committed before consequence observer')
    assert_eq(result, nil, 'participant has not resumed before resource consequence observer')
    assert_eq(log.resource[1].kind, 'wake', 'resource consequence is present in normalised log')
  end })
  rt:spawn(function()
    result = rt:perform(Op.access(Consequential, { tag = 'go' }))
    events[#events + 1] = 'resume'
  end, 'resource-consequence')
  assert_status(rt:run(), 'found')
  assert_eq(events[1], 'publish', 'resource consequence publishes before resume')
  assert_eq(events[2], 'resume', 'participant resumes after publish')
  assert_eq(result, true, 'participant receives result')
end

local function test_wrap_runs_after_publish()
  local events = {}
  local rt = Runtime.new({ on_consequence = function(_log)
    events[#events + 1] = 'publish'
  end })
  local result
  rt:spawn(function()
    result = rt:perform(Op.emit({ tag = 'explicit' }):and_then(function()
      return Op.always('value'):wrap(function(x)
        events[#events + 1] = 'wrap'
        return x .. '-wrapped'
      end)
    end))
  end, 'wrap-after-publish')
  assert_status(rt:run(), 'found')
  assert_eq(events[1], 'publish', 'publish precedes wrap')
  assert_eq(events[2], 'wrap', 'wrap runs during participant resumption')
  assert_eq(result, 'value-wrapped', 'wrapper result is participant-local')
end

local function test_map_over_open_bind_is_deferred()
  local rt = Runtime.new()
  local ch = Channel.new('ms6-map-open-bind')
  local result
  rt:spawn(function() rt:perform(ch:put_op(Op, 'x')) end, 'map-bind-sender')
  rt:spawn(function()
    result = rt:perform(
      ch:get_op(Op)
        :and_then(function(v) return Op.always(v .. 'y') end)
        :map(function(v) return v .. 'z' end)
    )
  end, 'map-bind-receiver')
  assert_status(rt:run(), 'found')
  assert_eq(result, 'xyz', 'map around open bind is deferred until match assignment')
end

local function test_wrap_over_open_bind_is_deferred()
  local rt = Runtime.new()
  local ch = Channel.new('ms6-wrap-open-bind')
  local events, result = {}, nil
  rt:spawn(function() rt:perform(ch:put_op(Op, 'x')) end, 'wrap-bind-sender')
  rt:spawn(function()
    result = rt:perform(
      ch:get_op(Op)
        :and_then(function(v) return Op.always(v .. 'y') end)
        :wrap(function(v)
          events[#events + 1] = 'wrap:' .. v
          return v .. 'z'
        end)
    )
  end, 'wrap-bind-receiver')
  assert_status(rt:run(), 'found')
  assert_eq(events[1], 'wrap:xy', 'wrap observes the result of the deferred bind')
  assert_eq(result, 'xyz', 'wrap around open bind runs after publication/resume')
end

local function test_bind_after_open_bind_is_deferred()
  local rt = Runtime.new()
  local ch = Channel.new('ms6-bind-open-bind')
  local result
  rt:spawn(function() rt:perform(ch:put_op(Op, 'x')) end, 'bind-bind-sender')
  rt:spawn(function()
    result = rt:perform(
      ch:get_op(Op)
        :and_then(function(v) return Op.always(v .. 'y') end)
        :and_then(function(v) return Op.always(v .. 'z') end)
    )
  end, 'bind-bind-receiver')
  assert_status(rt:run(), 'found')
  assert_eq(result, 'xyz', 'bind after open bind composes in the deferred continuation stack')
end

local function test_choice_branch_open_bind_plus_map()
  local rt = Runtime.new()
  local ch = Channel.new('ms6-choice-open-bind-map')
  local result
  rt:spawn(function() rt:perform(ch:put_op(Op, 'x')) end, 'choice-bind-sender')
  rt:spawn(function()
    result = rt:perform(Op.choice(
      ch:get_op(Op)
        :and_then(function(v) return Op.always(v .. 'y') end)
        :map(function(v) return v .. 'z' end),
      Op.always('fallback')
    ))
  end, 'choice-bind-receiver')
  assert_status(rt:run(), 'found')
  assert_eq(result, 'xyz', 'choice branch containing open bind plus map commits')
end

local function test_tensor_internal_recv_and_bind()
  local rt = Runtime.new()
  local ch = Channel.new('ms6-tensor-internal-bind')
  local result
  rt:spawn(function()
    result = rt:perform(Op.tensor({
      ch:put_op(Op, 'x'),
      ch:get_op(Op):and_then(function(v) return Op.always(v .. 'y') end),
    }))
  end, 'tensor-internal-bind')
  assert_status(rt:run(), 'found')
  assert_eq(result[1][1], true, 'internal send commits')
  assert_eq(result[2][1], 'xy', 'internal recv bind is continued by proof search')
end

local function test_tensor_internal_match_alternatives_search()
  local rt = Runtime.new()
  local ch = Channel.new('ms6-internal-match-alts')
  local c = Cell.new(0, 'ms6-internal-match-alts-cell')
  local result
  rt:spawn(function()
    result = rt:perform(Op.tensor({
      ch:put_op(Op, 'bad'),
      ch:put_op(Op, 'good'),
      ch:get_op(Op):and_then(function(v)
        if v == 'bad' then
          return c:set_op(Op, 1):map(function() return 'sensitive:' .. v end)
        end
        return Op.always('accepted:' .. v)
      end),
      ch:get_op(Op):and_then(function(v)
        return c:set_op(Op, 2):map(function() return 'other:' .. v end)
      end),
    }))
  end, 'tensor-internal-alts')
  assert_status(rt:run(), 'found')
  assert_eq(result[3][1], 'accepted:good', 'proof search skips the conflicting internal match pairing')
  assert_eq(result[4][1], 'other:bad', 'proof search commits the compatible internal match pairing')
  assert_eq(c.value, 2, 'only the compatible pairing mutates the cell')
end

local function test_tensor_internal_matches_appear_in_candidate_world()
  local ch = Channel.new('ms6-candidate-internal-match')
  local op = Op.tensor({ ch:put_op(Op, 'x'), ch:get_op(Op) })
  local attempt = { id = 'stable-attempt/internal-match' }
  local view = View.open('candidate-internal-match-view')
  local candidate = Phase.with('search', function(token)
    local frontier = assert_status(Frontier.expand(op, attempt, view, token), 'found')
    return ProofSearch.find(frontier, view, token)
  end)
  local world = assert_status(candidate, 'found')
  local internal = 0
  for i = 1, #(world.matches or {}) do
    if world.matches[i].kind == 'internal' then internal = internal + 1 end
  end
  assert_eq(internal, 1, 'CandidateWorld records the tensor-internal match')
end

local function test_rejected_deferred_generated_match_does_not_repeat()
  local first = Channel.new('ms6-stable-first')
  local second = Channel.new('ms6-stable-second')
  local ops = {
    first:put_op(Op, 'go'),
    first:get_op(Op):and_then(function()
      return second:get_op(Op)
    end),
    second:put_op(Op, 'A'),
    second:put_op(Op, 'B'),
  }
  local function make_inputs()
    local inputs = {}
    return Phase.with('search', function(token)
      for i = 1, #ops do
        local view = View.open('stable-deferred-' .. tostring(i))
        local frontier = assert_status(Frontier.expand(ops[i], { id = 'stable-deferred-attempt-' .. tostring(i) }, view, token), 'found')
        inputs[#inputs + 1] = { frontier = frontier, view = view }
      end
      return inputs
    end)
  end
  local inputs1 = make_inputs()
  local first_candidate = Phase.with('search', function(token)
    return ProofSearch.find(inputs1, nil, token)
  end)
  local c1 = assert_status(first_candidate, 'found')
  local inputs2 = make_inputs()
  local second_candidate = Phase.with('search', function(token)
    return ProofSearch.find(inputs2, nil, token, { rejected = { [c1.key] = true } })
  end)
  local c2 = assert_status(second_candidate, 'found')
  assert(c1.key ~= c2.key, 'rejecting one deferred-generated match leaves a different logical match available')
  assert(not c2.key:match(c1.key, 1, true), 'rejected candidate key is not repeated')
end

local function test_candidate_key_stable_across_repeated_search()
  local ch = Channel.new('ms6-stable-key')
  local op = Op.tensor({ ch:put_op(Op, 'x'), ch:get_op(Op):map(function(v) return v end) })
  local attempt = { id = 'stable-key-attempt' }
  local function key_for_new_frontier()
    return Phase.with('search', function(token)
      local view = View.open('stable-key-view')
      local frontier = assert_status(Frontier.expand(op, attempt, view, token), 'found')
      local candidate = assert_status(ProofSearch.find(frontier, view, token), 'found')
      return candidate.key
    end)
  end
  local k1 = key_for_new_frontier()
  local k2 = key_for_new_frontier()
  assert_eq(k1, k2, 'candidate key names the logical world, not fresh frame/open-claim allocation')
end

return function()
  test_open_bind_after_claim_completion_continues_root()
  test_map_over_open_bind_is_deferred()
  test_wrap_over_open_bind_is_deferred()
  test_bind_after_open_bind_is_deferred()
  test_choice_branch_open_bind_plus_map()
  test_tensor_internal_recv_and_bind()
  test_tensor_internal_match_alternatives_search()
  test_tensor_internal_matches_appear_in_candidate_world()
  test_rejected_deferred_generated_match_does_not_repeat()
  test_candidate_key_stable_across_repeated_search()
  test_open_bind_can_introduce_later_claim_completion()
  test_match_alternative_rejected_candidate_does_not_reject_other_match()
  test_no_resource_mutation_without_certificate()
  test_cert_apply_is_no_ordinary_failure_boundary()
  test_resource_consequence_precedes_resume()
  test_wrap_runs_after_publish()
  print('milestone 6 candidate/certificate tests: ok')
end

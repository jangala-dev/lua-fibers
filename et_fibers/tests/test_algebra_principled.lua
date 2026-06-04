package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

local Result = require('et.machine.kernel').Status
local Phase = require('et.machine.kernel').Phase
local Op = require('et.op')
local Runtime = require('et.runtime')
local Channel = require('et.resources.channel')
local Cell = require('et.resources.cell')
local Link = require('et.protocol').Link
local View = require('et.machine.frontier').View
local Frontier = require('et.machine.frontier').Frontier
local ProofSearch = require('et.machine.proofnet')
local Util = require('et.machine.kernel').Util
local Origin = require('et.machine.frontier').Origin
local Obligation = require('et.machine.frontier').Obligation

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

local function test_resource_access_returns_raw_values_to_bind()
  local rt = Runtime.new()
  local c = Cell.new(1, 'alg-raw-bind')
  local result
  rt:spawn(function()
    result = rt:perform(
      c:get_op(Op):and_then(function(v)
        return c:set_op(Op, v + 1):and_then(function()
          return c:get_op(Op)
        end)
      end)
    )
  end, 'raw-bind')
  assert_status(rt:run(), 'found')
  assert_eq(result, 2, 'bind sees the speculative raw value from resource fragments')
  assert_eq(c.value, 2, 'resource commit installs the fragment value')
end

local function test_map_and_bind_are_proof_reduction_operators()
  local view = View.open('alg-map-bind-proof')
  local op = Op.always(1)
    :map(function(x) return x, nil, x + 2 end)
    :and_then(function(a, b, c)
      assert_eq(b, nil, 'nil in raw proof row is preserved')
      return Op.always(a, c)
    end)
  local frontier = Phase.with('search', function(token)
    return Frontier.expand(op, { id = 'alg-map-bind-attempt' }, view, token)
  end)
  local f = assert_status(frontier, 'found')
  local frames = Phase.with('search', function(token) return f:probe(view, token) end)
  local frame = assert_status(frames, 'found')[1]
  local a, c = Util.unpack(frame.values)
  assert_eq(a, 1)
  assert_eq(c, 3)
end

local function test_or_else_absence_not_expansion_success()
  local rt = Runtime.new()
  local result
  rt:spawn(function()
    result = rt:perform(Op.never():or_else(Op.always('fallback')))
  end, 'or-else-never')
  assert_status(rt:run(), 'found')
  assert_eq(result, 'fallback', 'fallback commits when primary is truly absent')

  local rt2 = Runtime.new({ quiet_deadlock = true })
  local c = Cell.new(0, 'alg-or-else-fatal')
  local result2
  rt2:spawn(function()
    result2 = rt2:perform(Op.access(c, { tag = 'bogus' }):or_else(Op.always('fallback')))
  end, 'or-else-fatal')
  local st = rt2:run()
  assert_eq(st.tag, 'fatal', 'unsupported resource requests are fatal, not fallback absence')
  assert_eq(result2, nil)
end

local function test_nested_product_box_paths()
  do
    local rt = Runtime.new()
    local ch = Channel.new('alg-nested-tensor')
    local result
    rt:spawn(function()
      result = rt:perform(Op.tensor({ Op.tensor({ ch:put_op(Op, 'x'), ch:get_op(Op) }) }))
    end, 'nested-tensor')
    assert_status(rt:run(), 'found')
    assert_eq(result[1][1][1][1], true, 'nested tensor internal send commits')
    assert_eq(result[1][1][2][1], 'x', 'nested tensor internal receive commits')
  end

  do
    local rt = Runtime.new({ quiet_deadlock = true })
    local ch = Channel.new('alg-all-forbid')
    rt:spawn(function()
      rt:perform(Op.all({ ch:put_op(Op, 'x'), ch:get_op(Op) }))
    end, 'all-forbid')
    assert_eq(rt:run().tag, 'absent', 'all sibling lanes forbid same-root internal matches')
  end

  do
    local rt = Runtime.new()
    local ch = Channel.new('alg-all-inner-tensor')
    local result
    rt:spawn(function()
      result = rt:perform(Op.all({ Op.tensor({ ch:put_op(Op, 'x'), ch:get_op(Op) }) }))
    end, 'all-inner-tensor')
    assert_status(rt:run(), 'found')
    assert_eq(result[1][1][1][1], true, 'inner tensor may match within a single all lane')
    assert_eq(result[1][1][2][1], 'x', 'inner tensor receives within a single all lane')
  end

  do
    local rt = Runtime.new()
    local ch = Channel.new('alg-tensor-over-all')
    local result
    rt:spawn(function()
      result = rt:perform(Op.tensor({ Op.all({ ch:put_op(Op, 'x') }), Op.all({ ch:get_op(Op) }) }))
    end, 'tensor-over-all')
    assert_status(rt:run(), 'found')
    assert_eq(result[1][1][1][1], true, 'outer tensor permits match across all subtrees')
    assert_eq(result[2][1][1][1], 'x', 'outer tensor receive sees payload')
  end
end

local function test_product_lane_rows_are_preserved()
  local rt = Runtime.new()
  local result
  rt:spawn(function()
    result = rt:perform(Op.tensor({ Op.always('a', nil, 'c'), Op.always() }))
  end, 'row-product')
  assert_status(rt:run(), 'found')
  assert_eq(result[1].n, 3, 'first lane is a full value row')
  assert_eq(result[1][1], 'a')
  assert_eq(result[1][2], nil)
  assert_eq(result[1][3], 'c')
  assert_eq(result[2].n, 0, 'zero-value lane row is preserved')
end

local function test_candidate_world_selected_delta_is_explicit()
  local ch = Channel.new('alg-candidate-evidence')
  local op = Op.tensor({ ch:put_op(Op, 'x'), ch:get_op(Op) })
  local view = View.open('alg-candidate-view')
  local world = Phase.with('search', function(token)
    local frontier = assert_status(Frontier.expand(op, { id = 'alg-candidate-attempt' }, view, token), 'found')
    return ProofSearch.find(frontier, view, token)
  end)
  local candidate = assert_status(world, 'found')
  assert(#candidate.selected_occurrences >= 2, 'CandidateWorld records selected occurrences')
  assert(candidate.selected_delta, 'CandidateWorld carries selected delta')
  assert(candidate.selected_delta.consequences, 'selected delta carries consequences')
  assert_eq(#candidate.matches, 1, 'CandidateWorld records selected internal match')
  assert(candidate.selected_occurrences[1].origin_id ~= nil, 'selected occurrence has structured origin key')
end

local function test_candidate_world_has_event_structure_configuration()
  local ch = Channel.new('alg-candidate-config')
  local op = Op.tensor({ ch:put_op(Op, 'x'), ch:get_op(Op) })
  local view = View.open('alg-candidate-config-view')
  local candidate = Phase.with('search', function(token)
    local frontier = assert_status(Frontier.expand(op, { id = 'alg-candidate-config-attempt' }, view, token), 'found')
    return assert_status(ProofSearch.find(frontier, view, token), 'found')
  end)
  assert(candidate.configuration, 'CandidateWorld carries a selected-event configuration')
  assert(candidate.configuration:is_conflict_free(), 'configuration is conflict-free')
  local closed, edge = candidate.configuration:is_causally_closed()
  assert(closed, 'configuration is causally closed; missing edge ' .. tostring(edge and edge.cause))
  assert(#candidate.configuration.events >= #candidate.selected_occurrences, 'configuration exposes selected events')
  assert(#candidate.configuration.causes >= 1, 'configuration records causal edges')
end

local function test_split_consequences_publish_after_commit_before_resume()
  local events = {}
  local RClass = Link.resource {
    name = 'alg-resource-conseq',
    construct = function(self)
      self.id = 'alg-resource-conseq'; self.value = 0; self.version = 0
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
  local R = RClass.new()

  local rt = Runtime.new({ on_consequence = function(log)
    events[#events + 1] = 'publish'
    assert_eq(R.value, 1, 'resource state is committed before consequence publication')
    assert_eq(log.resource[1].kind, 'wake')
    assert_eq(log.transaction[1].tag, 'explicit')
  end })
  local result
  rt:spawn(function()
    result = rt:perform(Op.emit({ tag = 'explicit' }):and_then(function()
      return Op.access(R, { tag = 'go' }):wrap(function(x)
        events[#events + 1] = 'wrap'
        return x
      end)
    end))
    events[#events + 1] = 'resume'
  end, 'split-conseq')
  assert_status(rt:run(), 'found')
  assert_eq(result, true)
  assert_eq(events[1], 'publish', 'consequence publication precedes participant resumption')
  assert_eq(events[2], 'wrap', 'wrap remains participant-local post-commit code')
  assert_eq(events[3], 'resume')
end

local function test_obligation_refs_use_occurrence_identity()
  local root = Origin.root('alg-obligation-attempt')
  local b = { id = 'box', kind = 'tensor', allow_internal = true }
  local o1 = Origin.lane(root, b, 1)
  local o2 = Origin.lane(root, b, 2)
  local r1 = Obligation.ref(o1, 'settlement')
  local r1_again = Obligation.ref(o1, 'settlement')
  local r2 = Obligation.ref(o2, 'settlement')
  assert_eq(r1.id, r1_again.id, 'same occurrence gives same obligation identity')
  assert(r1.id ~= r2.id, 'different product lanes give different obligation identities')
  assert_eq(r1.origin_id, Origin.key(o1), 'obligation carries structured occurrence origin')
end

local function test_obligation_store_is_explicit_and_isolated()
  local root = Origin.root('alg-obligation-store')
  local s1 = Obligation.Store.new('store-1')
  local s2 = Obligation.Store.new('store-2')
  local r1 = s1:ref(root, 'settlement')
  local r2 = s2:ref(root, 'settlement')
  assert_eq(r1.id, r2.id, 'same occurrence identity can exist in separate stores')
  assert(r1.store ~= r2.store, 'refs remember their explicit store')
  assert_status(s1:publish(r1), 'found')
  assert_eq(s1:state(r1), 'pending')
  assert_eq(s2:state(r2), 'unpublished', 'second store is isolated')
end

local function test_function_fallback_law_is_not_supported()
  local ok = pcall(function()
    Op.always('primary'):or_else(function() return Op.always('fallback') end)
  end)
  assert_eq(ok, false, 'or_else fallback must be a Op expression, not a function')
end

return function()
  test_resource_access_returns_raw_values_to_bind()
  test_map_and_bind_are_proof_reduction_operators()
  test_or_else_absence_not_expansion_success()
  test_nested_product_box_paths()
  test_product_lane_rows_are_preserved()
  test_candidate_world_selected_delta_is_explicit()
  test_candidate_world_has_event_structure_configuration()
  test_split_consequences_publish_after_commit_before_resume()
  test_obligation_refs_use_occurrence_identity()
  test_obligation_store_is_explicit_and_isolated()
  test_function_fallback_law_is_not_supported()
  print('principled algebra/adversarial tests: ok')
end

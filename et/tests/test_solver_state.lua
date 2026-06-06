-- Shared solver state-transition invariants.

package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

local Op = require('et.op')
local Candidate = require('et.algebra.candidate')
local State = require('et.solver.state')

local function fail(msg) error(msg, 2) end
local function assert_eq(actual, expected, msg)
  if actual ~= expected then fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual)) end
end
local function assert_truthy(v, msg) if not v then fail(msg or 'expected truthy') end end
local function assert_falsy(v, msg) if v then fail((msg or 'expected falsy') .. ': got ' .. tostring(v)) end end

local function get_candidate(key)
  local ph = Candidate.new_ph()
  local c = Candidate.new(Op._pack(ph))
  c.endpoints[1] = { kind = 'rendezvous', primitive = 'channel', role = 'get', key = key, ph = ph }
  return c, ph
end

local function put_candidate(key, value)
  local c = Candidate.new(Op._pack(true))
  c.endpoints[1] = { kind = 'rendezvous', primitive = 'channel', role = 'put', key = key, value = value }
  return c
end

local function test_close_new_match_binds_substitution_and_does_not_mutate_seed()
  local key = {}
  local get, ph = get_candidate(key)
  local put = put_candidate(key, 'payload')
  put.fiber = {}

  local ns, nb = State.with_match({ get }, {}, 1, 1, { kind = 'new', cand = put, ei = 1 })
  assert_truthy(ns, 'new candidate match should close')
  assert_eq(#ns, 2)
  assert_eq(#ns[1].endpoints, 0, 'get endpoint removed')
  assert_eq(#ns[2].endpoints, 0, 'put endpoint removed')
  assert_eq(Candidate.resolve(ph, ns[1].subst), 'payload', 'get placeholder resolved through substitution')
  assert_eq(#get.endpoints, 1, 'source selected state is not mutated')
  assert_truthy(nb[put.fiber], 'new candidate fibre is marked selected')
end

local function test_close_selected_match_handles_removal_order()
  local key = {}
  local get, ph = get_candidate(key)
  local put = put_candidate(key, 'selected-payload')

  local ns, nb = State.with_match({ get, put }, {}, 1, 1, { kind = 'selected', ci = 2, ei = 1 })
  assert_truthy(ns, 'selected candidate match should close')
  assert_eq(#ns, 2)
  assert_eq(#ns[1].endpoints, 0)
  assert_eq(#ns[2].endpoints, 0)
  assert_eq(Candidate.resolve(ph, ns[1].subst), 'selected-payload')
  assert_truthy(nb)
end

local function test_non_matching_rendezvous_is_rejected()
  local left = get_candidate({})
  local right = put_candidate({}, 'wrong-key')
  local ns = State.with_match({ left }, {}, 1, 1, { kind = 'new', cand = right, ei = 1 })
  assert_falsy(ns, 'different keys do not close')
end

local function test_with_deferred_branch_replaces_only_the_selected_slot()
  local a = Candidate.new(Op._pack('a'))
  local b = Candidate.new(Op._pack('b'))
  local replacement = Candidate.new(Op._pack('replacement'))

  local ns = State.with_deferred_branch({ a, b }, {}, 2, replacement)
  assert_truthy(ns)
  assert_eq(ns[1].vals[1], 'a')
  assert_eq(ns[2].vals[1], 'replacement')
  assert_eq(b.vals[1], 'b', 'original deferred candidate is untouched')
end

local function test_closed_world_requires_no_pending_endpoints()
  local key = {}
  local open = get_candidate(key)
  assert_eq(State.closed_world({ open }), nil, 'world with endpoint is not closed')
  local closed = Candidate.new(Op._pack('done'))
  local w = State.closed_world({ closed })
  assert_truthy(w and w.tag == 'world', 'endpoint-free combo is a closed world')
end

local tests = {
  test_close_new_match_binds_substitution_and_does_not_mutate_seed,
  test_close_selected_match_handles_removal_order,
  test_non_matching_rendezvous_is_rejected,
  test_with_deferred_branch_replaces_only_the_selected_slot,
  test_closed_world_requires_no_pending_endpoints,
}

for i = 1, #tests do tests[i]() end
print('tests/test_solver_state.lua: ok')

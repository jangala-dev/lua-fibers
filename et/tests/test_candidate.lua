-- Candidate substitution and clone invariants.

package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

local Op = require('et.op')
local Candidate = require('et.algebra.candidate')

local function fail(msg) error(msg, 2) end
local function assert_eq(actual, expected, msg)
  if actual ~= expected then fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual)) end
end
local function assert_truthy(v, msg) if not v then fail(msg or 'expected truthy') end end
local function assert_falsy(v, msg) if v then fail((msg or 'expected falsy') .. ': got ' .. tostring(v)) end end

local function test_clone_shares_values_but_not_substitution()
  local ph = Candidate.new_ph()
  local nested = { 'prefix', ph, n = 2 }
  local c = Candidate.new(Op._pack(nested))
  local d = Candidate.clone(c)

  assert_eq(d.vals, c.vals, 'clone shares persistent value pack')
  assert_eq(d.vals[1], nested, 'clone shares nested persistent values')
  assert_falsy(Candidate.raw_resolved(c.vals, c.subst), 'original starts unresolved')
  assert_falsy(Candidate.raw_resolved(d.vals, d.subst), 'clone starts unresolved')

  Candidate.subst_bind(d, ph, 'resolved')
  assert_truthy(Candidate.raw_resolved(d.vals, d.subst), 'clone resolves through its own substitution')
  assert_falsy(Candidate.raw_resolved(c.vals, c.subst), 'original is not affected by clone substitution')

  local resolved = Candidate.resolve_pack(d.vals, d.subst)
  assert_eq(resolved[1][1], 'prefix')
  assert_eq(resolved[1][2], 'resolved')
  assert_eq(nested[2], ph, 'persistent source value is not mutated by resolve')
end

local function test_nil_substitution_is_a_real_resolution()
  local ph = Candidate.new_ph()
  local c = Candidate.new(Op._pack(ph, 'tail'))
  Candidate.subst_bind(c, ph, nil)

  assert_truthy(Candidate.raw_resolved(c.vals, c.subst), 'nil is a valid placeholder resolution')
  local resolved = Candidate.resolve_pack(c.vals, c.subst)
  assert_eq(resolved.n, 2)
  assert_eq(resolved[1], nil)
  assert_eq(resolved[2], 'tail')
end

local function test_substitution_merges_across_candidate_products()
  local ph_a = Candidate.new_ph()
  local ph_b = Candidate.new_ph()
  local a = Candidate.new(Op._pack(ph_a))
  local b = Candidate.new(Op._pack(ph_b))
  Candidate.subst_bind(a, ph_a, 'a')
  Candidate.subst_bind(b, ph_b, 'b')

  local p = Candidate.combine_parallel(a, b)
  assert_truthy(p, 'compatible substitutions combine in parallel')
  assert_eq(Candidate.resolve(ph_a, p.subst), 'a')
  assert_eq(Candidate.resolve(ph_b, p.subst), 'b')

  local q = Candidate.combine_seq(a, b)
  assert_truthy(q, 'compatible substitutions combine sequentially')
  assert_eq(Candidate.resolve(ph_a, q.subst), 'a')
  assert_eq(Candidate.resolve(ph_b, q.subst), 'b')
end

local function test_conflicting_substitution_rejects_candidate_product()
  local ph = Candidate.new_ph()
  local a = Candidate.new(Op._pack())
  local b = Candidate.new(Op._pack())
  Candidate.subst_bind(a, ph, 'left')
  Candidate.subst_bind(b, ph, 'right')

  assert_eq(Candidate.combine_parallel(a, b), nil, 'parallel conflict is rejected')
  assert_eq(Candidate.combine_seq(a, b), nil, 'sequential conflict is rejected')
end

local tests = {
  test_clone_shares_values_but_not_substitution,
  test_nil_substitution_is_a_real_resolution,
  test_substitution_merges_across_candidate_products,
  test_conflicting_substitution_rejects_candidate_product,
}

for i = 1, #tests do tests[i]() end
print('tests/test_candidate.lua: ok')

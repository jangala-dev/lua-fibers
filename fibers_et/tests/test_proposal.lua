-- Proposal substitution and clone invariants.

package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

local Op = require('fibers.atoms.op')
local Proposal = require('fibers.kernel.resources.proposal')

local function fail(msg) error(msg, 2) end
local function assert_eq(actual, expected, msg)
  if actual ~= expected then fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual)) end
end
local function assert_truthy(v, msg) if not v then fail(msg or 'expected truthy') end end
local function assert_falsy(v, msg) if v then fail((msg or 'expected falsy') .. ': got ' .. tostring(v)) end end

local function test_clone_copies_structural_values_but_not_opaque_user_values()
  local ph = Proposal.new_ph()
  local nested = { 'prefix', ph, n = 2, _fibers_rows = true }
  local c = Proposal.new(Op._pack(nested))
  local d = Proposal.clone(c)

  if d.vals == c.vals then fail('clone should copy structural value pack for branch-local result updates') end
  if d.vals[1] == nested then fail('clone should copy nested structural rows for branch-local result updates') end
  assert_falsy(Proposal.raw_resolved(c.vals, c.subst), 'original starts unresolved')
  assert_falsy(Proposal.raw_resolved(d.vals, d.subst), 'clone starts unresolved')

  Proposal.subst_bind(d, ph, 'resolved')
  assert_truthy(Proposal.raw_resolved(d.vals, d.subst), 'clone resolves through its own substitution')
  assert_falsy(Proposal.raw_resolved(c.vals, c.subst), 'original is not affected by clone substitution')

  local resolved = Proposal.resolve_pack(d.vals, d.subst)
  assert_eq(resolved[1][1], 'prefix')
  assert_eq(resolved[1][2], 'resolved')
  assert_eq(nested[2], ph, 'persistent source value is not mutated by resolve')

  local user = { x = 1 }
  local u = Proposal.new(Op._pack(user))
  local u2 = Proposal.clone(u)
  assert_eq(u2.vals[1], user, 'opaque user tables remain shared values')
end

local function test_nil_substitution_is_a_real_resolution()
  local ph = Proposal.new_ph()
  local c = Proposal.new(Op._pack(ph, 'tail'))
  Proposal.subst_bind(c, ph, nil)

  assert_truthy(Proposal.raw_resolved(c.vals, c.subst), 'nil is a valid placeholder resolution')
  local resolved = Proposal.resolve_pack(c.vals, c.subst)
  assert_eq(resolved.n, 2)
  assert_eq(resolved[1], nil)
  assert_eq(resolved[2], 'tail')
end

local function test_clone_preserves_resource_deltas()
  local Scalar = require('fibers.atoms.scalar')
  local Resource = require('fibers.kernel.resources.protocol')
  local scalar = Scalar.new('x', 'proposal-clone-scalar')
  local p = Proposal.new(Op._pack('ok'))
  local rec = Resource.ensure(p, scalar, scalar._fibers_kind)
  rec.write = 'y'
  local q = Proposal.clone(p)
  assert_eq(q.res[scalar].write, 'y', 'resource record is copied')
  q.res[scalar].write = 'z'
  assert_eq(p.res[scalar].write, 'y', 'clone does not mutate original resource record')
end

local tests = {
  test_clone_copies_structural_values_but_not_opaque_user_values,
  test_nil_substitution_is_a_real_resolution,
  test_clone_preserves_resource_deltas,
}

for i = 1, #tests do tests[i]() end
print('tests/test_proposal.lua: ok')

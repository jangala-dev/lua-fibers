-- General proof-premise contract tests.
-- Rendezvous is implemented as the first premise resolver; these tests are
-- intentionally small because the public algebra tests cover the wider
-- rendezvous behaviour.

package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

local Op = require('fibers.atoms.op')
local Rendezvous = require('fibers.atoms.rendezvous')
local Runtime = require('fibers.kernel.runtime')
local Result = require('fibers.kernel.resources.result')
local Resources = require('fibers.kernel.resources')
local ContributionSet = require('fibers.kernel.resources.contribution_set')
local Proposal = require('fibers.kernel.resources.proposal')

local function fail(msg) error(msg, 2) end
local function assert_eq(actual, expected, msg)
  if actual ~= expected then fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual)) end
end
local function assert_truthy(value, msg) if not value then fail(msg or 'expected truthy') end end
local function assert_nil(value, msg) if value ~= nil then fail((msg or 'expected nil') .. ': got ' .. tostring(value)) end end

local function assert_status(status, tag, msg)
  if not status or status.tag ~= tag then fail((msg or 'status mismatch') .. ': expected ' .. tostring(tag) .. ', got ' .. tostring(status and status.tag)) end
end

local function new_runtime(opts) return Runtime.new(opts or {}) end

local function test_result_premise_is_public_kernel_result()
  local p = Result.premise({ role = 'x' })
  assert_eq(p.status, 'premise')
  assert_eq(p.premise.role, 'x')
end


local function test_contribution_set_deduplicates_shared_solution_proposals()
  local set = ContributionSet.empty()
  local p = Proposal.new(Op._pack(true))
  local ok, err = set:add('solution-1', p)
  assert_truthy(ok, err and err.message or 'first contribution add failed')
  ok, err = set:add('solution-1', p)
  assert_truthy(ok, err and err.message or 'duplicate contribution add failed')
  assert_eq(#set:items(), 1, 'same contribution id should be carried once')
end

local function test_rendezvous_kind_uses_premise_resolver()
  assert_truthy(Rendezvous.Kind.resolve_premises, 'rendezvous kind exposes premise resolver')
  assert_nil(Resources.rendezvous_leaf, 'old rendezvous_leaf special casing should not be present')
end

local function test_rendezvous_premise_delivers_concrete_lua_value_to_bind()
  local rt = new_runtime()
  local ch = Rendezvous.new('premise-bind')
  local out

  rt:spawn_raw(function()
    out = rt:perform(ch:get_op():and_then(function(v)
      assert_eq(type(v), 'table', 'bind should receive concrete table value')
      assert_eq(v.kind, 'payload')
      return Op.always(v.n + 1)
    end))
  end, 'receiver')

  rt:spawn_raw(function()
    rt:perform(ch:put_op({ kind = 'payload', n = 41 }))
  end, 'sender')

  assert_status(rt:run(), 'found')
  assert_eq(out, 42)
end

local function test_tensor_internal_rendezvous_is_resolved_by_premise_solution()
  local rt = new_runtime()
  local ch = Rendezvous.new('premise-tensor')
  local rows

  rt:spawn_raw(function()
    rows = rt:perform(Op.tensor({
      ch:get_op():map(function(v) return 'got:' .. v end),
      ch:put_op('x'),
    }))
  end, 'tensor-root')

  assert_status(rt:run(), 'found')
  assert_eq(rows[1][1], 'got:x')
  assert_eq(rows[2][1], true)
end

local function test_all_still_blocks_internal_rendezvous()
  local rt = new_runtime({ quiet_deadlock = true })
  local ch = Rendezvous.new('premise-all')
  local rows

  rt:spawn_raw(function()
    rows = rt:perform(Op.all({ ch:get_op(), ch:put_op('x') }))
  end, 'all-root')

  local status = rt:run()
  local tag = status and status.tag
  if tag ~= 'absent' and tag ~= 'pending' and tag ~= 'conflict' and tag ~= 'reject_candidate' then
    fail('all should not allow internal rendezvous; got ' .. tostring(tag))
  end
  assert_nil(rows, 'all root should not resume')
end

local tests = {
  test_result_premise_is_public_kernel_result,
  test_contribution_set_deduplicates_shared_solution_proposals,
  test_rendezvous_kind_uses_premise_resolver,
  test_rendezvous_premise_delivers_concrete_lua_value_to_bind,
  test_tensor_internal_rendezvous_is_resolved_by_premise_solution,
  test_all_still_blocks_internal_rendezvous,
}

for i = 1, #tests do tests[i]() end

print('tests/test_premises.lua: ok')

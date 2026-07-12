package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

local Op = require('fibers.atoms.op')
local IR = require('fibers.kernel.ir')
local Runtime = require('fibers.kernel.runtime')
local Rendezvous = require('fibers.atoms.rendezvous')
local Scalar = require('fibers.atoms.scalar')
local BranchPolicy = require('fibers.kernel.branch_policy')
local fibers = require('fibers')

local function truthy(v, m) if not v then error(m or 'expected truthy value', 2) end end
local function eq(a, b, m) if a ~= b then error((m or 'values differ') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2) end end

-- Compiled operation metadata distinguishes solver-visible continuations from
-- the conservative opaque Lua path.
local mapped = Op.always(1):map(function(x) return x + 1 end)
eq(IR.metadata(mapped).dynamic, false, 'map should be statically closed')

local opaque = Op.always():and_then(function() return Op.always() end)
eq(IR.metadata(opaque).dynamic, true, 'unhinted and_then should remain conservative')

local hinted_channel = Rendezvous.new('metadata-hinted')
local hinted = Op.always():and_then(function() return hinted_channel:get_op() end,
  Op.dependencies(hinted_channel:get_op()))
eq(IR.metadata(hinted).dynamic, false, 'hinted and_then should be analysable')
truthy(IR.metadata(hinted).exchanges[hinted_channel].get, 'hinted exchange dependency missing')


-- Optional development-time verification rejects an incomplete continuation
-- declaration while leaving the ordinary conservative path unchanged.
local declared_channel = Rendezvous.new('declared-continuation')
local actual_channel = Rendezvous.new('actual-continuation')
local verified = Runtime.new({ verify_dependencies = true })
verified:spawn_raw(function()
  verified:perform(Op.guard(function() return actual_channel:get_op() end,
    Op.dependencies(declared_channel:get_op())))
end)
local verify_ok, verify_err = pcall(function() verified:run() end)
eq(verify_ok, false, 'incomplete continuation metadata should be rejected')
truthy(tostring(verify_err):find('continuation dependency declaration is incomplete', 1, true),
  'dependency verification error was not reported')


-- The principal structured-concurrency path also satisfies its internal
-- continuation declarations when verification is enabled.
local verified_channel = fibers.Rendezvous.new('verified-structured')
local verified_value = fibers.run(function()
  local task = fibers.spawn(function()
    return fibers.perform(verified_channel:get_op())
  end, 'verified-receiver')
  fibers.perform(verified_channel:put_op(17))
  return fibers.perform(task:await_op())
end, { verify_dependencies = true })
eq(verified_value, 17, 'valid structured dependency declarations were rejected')

-- Independent static requests are isolated before proof search.
local isolated = Runtime.new({ instrumentation = true })
for i = 1, 20 do
  local ch = Rendezvous.new('isolated-' .. tostring(i))
  isolated:spawn_raw(function() isolated:perform(ch:get_op()) end)
end
eq(isolated:run().tag, 'quiescent')
local isolated_snap = isolated:instrumentation_snapshot()
truthy((isolated_snap.maxima.component_size or 20) < 20, 'unrelated roots were not isolated')
truthy((isolated_snap.counters.component_roots_excluded or 0) > 0, 'component exclusion was not measured')

-- An opaque continuation deliberately joins the full pending frontier.
local global = Runtime.new({ instrumentation = true, dependency_index_threshold = 1 })
local a, b = Rendezvous.new('global-a'), Rendezvous.new('global-b')
global:spawn_raw(function() global:perform(Op.guard(function() return a:get_op() end)) end)
global:spawn_raw(function() global:perform(b:get_op()) end)
eq(global:run().tag, 'quiescent')
local global_snap = global:instrumentation_snapshot()
truthy((global_snap.counters.component_global_plans or 0) > 0, 'opaque continuation did not force conservative component')
eq(global_snap.maxima.component_size, 2, 'opaque continuation should join both roots')


-- With the index active, several independent committing components retain their
-- own participants and all reach the same result under both evaluators.
local function independent_components(machine)
  local rt = Runtime.new({
    machine = machine,
    instrumentation = true,
    dependency_index_threshold = 1,
    dependency_index_release_threshold = 0,
  })
  local values = {}
  for i = 1, 8 do
    local index, expected = i, i * 10
    local channel = Rendezvous.new('component-commit-' .. machine .. '-' .. tostring(i))
    rt:spawn_raw(function() values[index] = rt:perform(channel:get_op()) end)
    rt:spawn_raw(function() rt:perform(channel:put_op(expected)) end)
  end
  local status
  repeat status = rt:run() until status.tag ~= 'found'
  for i = 1, 8 do eq(values[i], i * 10, 'component result missing') end
  local snap = rt:instrumentation_snapshot()
  truthy((snap.counters.component_roots_excluded or 0) > 0, 'committing components were not isolated')
  return status.tag
end
eq(independent_components('trail'), independent_components('reference'),
  'evaluators disagree on independent component completion')

-- A fully determined binary exchange is normalised rather than branched.
local binary = Runtime.new({ instrumentation = true })
local ch = Rendezvous.new('forced-binary')
local got
binary:spawn_raw(function() got = binary:perform(ch:get_op()) end)
binary:spawn_raw(function() binary:perform(ch:put_op('ok')) end)
eq(binary:run().tag, 'found')
eq(got, 'ok')
local binary_snap = binary:instrumentation_snapshot()
truthy((binary_snap.counters.forced_exchanges or 0) > 0, 'binary exchange reduction was not used')

-- A sole non-supplying scalar query is likewise a forced claim resolution.
local claim_rt = Runtime.new({ instrumentation = true })
local scalar = Scalar.machine(7, 'forced-claim')
local claim_result
claim_rt:spawn_raw(function() claim_result = claim_rt:perform(scalar:expect_op(7)) end)
eq(claim_rt:run().tag, 'found')
eq(claim_result, true)
local claim_snap = claim_rt:instrumentation_snapshot()
truthy((claim_snap.counters.forced_claims or 0) > 0, 'forced claim reduction was not used')

-- The residual exchange policy chooses the smallest viable domain.
local r1, r2 = {}, {}
local intents = {
  { id = 1, kind = 'exchange', resource = r1, role = 'put' },
  { id = 2, kind = 'exchange', resource = r1, role = 'put' },
  { id = 3, kind = 'exchange', resource = r1, role = 'get' },
  { id = 4, kind = 'exchange', resource = r1, role = 'get' },
  { id = 5, kind = 'exchange', resource = r2, role = 'put' },
  { id = 6, kind = 'exchange', resource = r2, role = 'get' },
}
local by_id = {}; for i = 1, #intents do by_id[intents[i].id] = intents[i] end
local frontier = BranchPolicy.exchange_frontier({
  intents = intents, intent_by_id = by_id,
  exchange_resources = { r1, r2 },
  exchange_index = {
    [r1] = { put = { 1, 2 }, get = { 3, 4 } },
    [r2] = { put = { 5 }, get = { 6 } },
  },
}, function() return true end, true)
eq(frontier.selected.id, 5, 'most-constrained exchange was not selected')
eq(#frontier.pairs, 1, 'selected domain should contain one pair')

-- Production and reference evaluators retain the same committed result.
local function scenario(machine)
  local rt = Runtime.new({ machine = machine, instrumentation = true })
  local c = Rendezvous.new('differential-' .. machine)
  local value
  rt:spawn_raw(function() value = rt:perform(c:get_op()) end)
  rt:spawn_raw(function() rt:perform(c:put_op(42)) end)
  local status = rt:run()
  return status.tag, value
end
local at, av = scenario('trail')
local bt, bv = scenario('reference')
eq(at, bt, 'machines disagree on status')
eq(av, bv, 'machines disagree on value')

print('tests/test_performance_architecture.lua: ok')

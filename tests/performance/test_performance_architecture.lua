package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './reference/?.lua',
  './reference/?/init.lua',
  './reference/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

local Op = require('fibers.op')
local IR = require('fibers.internal.kernel.ir')
local Runtime = require('fibers.runtime')
local Rendezvous = require('fibers.resource.rendezvous')
local Cell = require('fibers.resource.cell')
local StateMachine = require('fibers.resource.machine')
local BranchPolicy = require('fibers.internal.kernel.domain')
local fibers = require('fibers')
local FibersRendezvous = require('fibers.resource.rendezvous')

local function truthy(v, m)
  if not v then
    error(m or 'expected truthy value', 2)
  end
end
local function eq(a, b, m)
  if a ~= b then
    error((m or 'values differ') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2)
  end
end

-- Compiled option metadata distinguishes solver-visible continuations from
-- the conservative opaque Lua path.
local mapped = Op.always(1):map(function(x)
  return x + 1
end)
eq(IR.metadata(mapped).dynamic, false, 'map should be statically closed')

local opaque = Op.always():and_then(function()
  return Op.always()
end)
eq(IR.metadata(opaque).dynamic, true, 'unhinted and_then should remain conservative')

local hinted_channel = Rendezvous.new('metadata-hinted')
local hinted = Op.always():and_then(function()
  return hinted_channel:get_op()
end, Op.dependencies(hinted_channel:get_op()))
eq(IR.metadata(hinted).dynamic, false, 'hinted and_then should be analysable')
truthy(IR.metadata(hinted).exchanges[hinted_channel].get, 'hinted exchange dependency missing')

-- Optional development-time verification rejects an incomplete continuation
-- declaration while leaving the ordinary conservative path unchanged.
local declared_channel = Rendezvous.new('declared-continuation')
local actual_channel = Rendezvous.new('actual-continuation')
local verified = Runtime.new({ verify_dependencies = true })
verified:spawn_raw(function()
  verified:perform(Op.guard(function()
    return actual_channel:get_op()
  end, Op.dependencies(declared_channel:get_op())))
end)
local verify_ok, verify_err = pcall(function()
  verified:run()
end)
eq(verify_ok, false, 'incomplete continuation metadata should be rejected')
truthy(
  tostring(verify_err):find('continuation dependency declaration is incomplete', 1, true),
  'dependency verification error was not reported'
)

-- The principal structured-concurrency path also satisfies its internal
-- continuation declarations when verification is enabled.
local verified_channel = FibersRendezvous.new('verified-structured')
local verified_value = fibers.run(function()
  local task = fibers.spawn(function()
    return fibers.perform(verified_channel:get_op())
  end, 'verified-receiver')
  fibers.perform(verified_channel:put_op(17))
  return fibers.perform(task:await_op())
end, { verify_dependencies = true })
eq(verified_value, 17, 'valid structured dependency declarations were rejected')

-- Pending requests and blocked demands use the same interned atom and dense
-- sparse-set bucket representation.  Membership updates advance one generation
-- without changing atom identity.
do
  local Dependencies = require('fibers.internal.kernel.dependencies')
  local index = Dependencies.Index.new()
  local resource = Rendezvous.new('atom-bucket')
  local requests = {}
  local role = index:atom('exchange', resource, 'get')
  for i = 1, 6 do
    local request = { id = i, op = resource:get_op() }
    request.metadata = IR.metadata(request.op)
    requests[i] = request
    index:add(request)
    eq(role.count, i, 'dependency atom membership count')
    eq(role.items[role.positions[i]], i, 'dense dependency membership position')
  end
  local generation = role.generation
  index:remove(requests[6])
  truthy(role.generation > generation, 'dependency atom removal did not advance its generation')
  eq(role.count, 5, 'dependency atom removal count')
  for i = 5, 1, -1 do
    index:remove(requests[i])
  end
  eq(role.count, 0, 'empty dependency atom retained request membership')
  eq(index:atom('exchange', resource, 'get'), role, 'dependency atom identity was not interned')
end

-- Location touch and directional-supply memberships are compiled into atoms and
-- retire their request membership when the request leaves the pending index.
do
  local Dependencies = require('fibers.internal.kernel.dependencies')
  local index = Dependencies.Index.new()
  local cell = StateMachine.new(0, 'retired-location-atom')
  local request = { id = 1, op = cell:write_op(1) }
  request.metadata = IR.metadata(request.op)
  index:add(request)
  local location, access
  for value, modes in pairs(request.metadata.locations) do
    location, access = value, modes
    break
  end
  local touch = index:atom('location', location, 'touch')
  eq(touch.count, 1, 'location touch atom was not populated')
  local supply_atoms = {}
  for direction in pairs((access and access.supplies) or {}) do
    local atom = index:atom('supply', location, direction)
    supply_atoms[#supply_atoms + 1] = atom
    eq(atom.count, 1, 'directional supply atom was not populated')
  end
  index:remove(request)
  eq(touch.count, 0, 'location touch atom retained request membership')
  for i = 1, #supply_atoms do
    eq(supply_atoms[i].count, 0, 'directional supply atom retained request membership')
  end
  eq(request._dependency_plan, nil, 'retired request retained its dependency plan')
end

-- Independent static requests are isolated before proof search.
local isolated = Runtime.new({ instrumentation = true })
for i = 1, 20 do
  local ch = Rendezvous.new('isolated-' .. tostring(i))
  isolated:spawn_raw(function()
    isolated:perform(ch:get_op())
  end)
end
eq(isolated:run().tag, 'quiescent')
local isolated_snap = isolated:instrumentation_report()
truthy((isolated_snap.maxima.component_size or 20) < 20, 'unrelated roots were not isolated')
truthy((isolated_snap.counters.component_roots_excluded or 0) > 0, 'component exclusion was not measured')

-- An unopened guard begins conservatively, then its fixed root residual is
-- reindexed to the exact dependency rather than permanently joining unrelated
-- pending roots.
local global = Runtime.new({ instrumentation = true, dependency_index_threshold = 1 })
local a, b = Rendezvous.new('global-a'), Rendezvous.new('global-b')
global:spawn_raw(function()
  global:perform(Op.guard(function()
    return a:get_op()
  end))
end)
global:spawn_raw(function()
  global:perform(b:get_op())
end)
eq(global:run().tag, 'quiescent')
local global_snap = global:instrumentation_report()
truthy(
  (global_snap.counters.dynamic_dependency_refinements or 0) > 0,
  'revealed guard did not refine its dependency plan'
)
eq(global_snap.maxima.component_size, 1, 'revealed guard should not retain an unrelated root')

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
    rt:spawn_raw(function()
      values[index] = rt:perform(channel:get_op())
    end)
    rt:spawn_raw(function()
      rt:perform(channel:put_op(expected))
    end)
  end
  local status
  repeat
    status = rt:run()
  until status.tag ~= 'found'
  for i = 1, 8 do
    eq(values[i], i * 10, 'component result missing')
  end
  local snap = rt:instrumentation_report()
  truthy((snap.counters.component_roots_excluded or 0) > 0, 'committing components were not isolated')
  return status.tag
end
eq(
  independent_components('ledger'),
  independent_components('reference'),
  'evaluators disagree on independent component completion'
)

-- Choice traversal generations are local to the dependency component.
-- Unrelated admissions preserve the generation; a possible partner changes it.
do
  local rt = Runtime.new({ choice_seed = 7 })
  local primary = Rendezvous.new('choice-generation-primary')
  local unrelated = Rendezvous.new('choice-generation-unrelated')
  rt:spawn_raw(function()
    rt:perform(primary:get_op())
  end)
  rt:_pump()
  rt:_index_pending_frontier()
  local focus = rt.pending[1].id
  local _, before = rt:_component_requests(focus)

  rt:spawn_raw(function()
    rt:perform(unrelated:get_op())
  end)
  rt:_start_one()
  local _, after_unrelated = rt:_component_requests(focus)
  eq(
    after_unrelated.order_generation,
    before.order_generation,
    'unrelated admission changed component-local choice generation'
  )

  rt:spawn_raw(function()
    rt:perform(primary:put_op('ready'))
  end)
  rt:_start_one()
  local _, after_related = rt:_component_requests(focus)
  truthy(
    after_related.order_generation ~= before.order_generation,
    'possible partner did not change component-local choice generation'
  )
end

-- A fully determined binary exchange is normalised rather than branched.
local binary = Runtime.new({ instrumentation = true })
local ch = Rendezvous.new('forced-binary')
local got
binary:spawn_raw(function()
  got = binary:perform(ch:get_op())
end)
binary:spawn_raw(function()
  binary:perform(ch:put_op('ok'))
end)
eq(binary:run().tag, 'found')
eq(got, 'ok')
local binary_snap = binary:instrumentation_report()
truthy((binary_snap.counters.forced_exchanges or 0) > 0, 'binary exchange reduction was not used')

-- Empty transactional collections are shared rather than allocated afresh for
-- a rendezvous which neither observes nor writes committed state.
do
  local Store = require('fibers.internal.kernel.ledger')
  local rt = Runtime.new()
  local c = Rendezvous.new('empty-candidate-state')
  rt:spawn_raw(function()
    rt:perform(c:get_op())
  end)
  rt:spawn_raw(function()
    rt:perform(c:put_op(1))
  end)
  rt:_pump()
  local candidate = assert(rt:_find_candidate(rt.pending[1].id))
  if rt.machine_name == 'ledger' then
    truthy(candidate._fibers_session_hit == true, 'production hit was copied into a detached candidate')
  end
  eq(candidate.observations, nil, 'empty observations should remain absent')
  eq(candidate.writes, nil, 'empty writes should remain absent')
  eq(candidate.effects, nil, 'empty effects were materialised')
  eq(candidate.absence_gate, nil, 'empty absence gate was materialised')
  truthy(rt:_commit_hit(candidate), 'empty-state candidate did not commit')
end

-- Completed production sessions return their cleared arenas to a runtime-local
-- pool and are reused by the following transaction.
do
  local rt = Runtime.new({ instrumentation = true })
  local values = {}
  for i = 1, 2 do
    rt:spawn_raw(function()
      values[i] = rt:perform(Op.always(i))
    end)
    while rt:run().tag == 'found' do
    end
  end
  eq(values[1], 1, 'first pooled session result')
  eq(values[2], 2, 'second pooled session result')
  if rt.machine_name == 'ledger' then
    local counters = rt:instrumentation_report().counters
    truthy((counters.search_session_reuses or 0) > 0, 'search-session arena was not reused')
    truthy(#rt._search_session_pool > 0, 'cleared session was not returned to the pool')
    local pooled = rt._search_session_pool[#rt._search_session_pool]
    eq(next(pooled.state.tasks), nil, 'pooled task arena retained a task')
    eq(next(pooled.state.segments), nil, 'pooled segment arena retained a segment')
    eq(next(pooled.state.intents), nil, 'pooled intent arena retained an intent')
  end
end

-- A sole non-supplying cell query is likewise a forced claim resolution.
local claim_rt = Runtime.new({ instrumentation = true })
local cell = StateMachine.new(7, 'forced-claim')
local claim_result
claim_rt:spawn_raw(function()
  claim_result = claim_rt:perform(cell:expect_op(7))
end)
eq(claim_rt:run().tag, 'found')
eq(claim_result, true)
local claim_snap = claim_rt:instrumentation_report()
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
local demand_runtime = { certified_symmetry = false }
local demand_index = BranchPolicy.new(demand_runtime)
for i = 1, #intents do
  BranchPolicy.add(demand_index, intents[i])
end
local domain = BranchPolicy.open(demand_index, {
  runtime = demand_runtime,
  intents = intents,
}, function()
  return true
end, true)
eq(domain.exchange.selected.id, 5, 'most-constrained exchange was not selected')
local alternative = BranchPolicy.next(BranchPolicy.cursor(domain), {
  witness_cursor = function()
    error('unexpected witness')
  end,
  supplier = function()
    return nil
  end,
})
eq(alternative.pair.left, 5, 'selected exchange pair changed')
eq(alternative.pair.right, 6, 'selected exchange pair changed')

-- Production and reference evaluators retain the same committed result.
local function scenario(machine)
  local rt = Runtime.new({ machine = machine, instrumentation = true })
  local c = Rendezvous.new('differential-' .. machine)
  local value
  rt:spawn_raw(function()
    value = rt:perform(c:get_op())
  end)
  rt:spawn_raw(function()
    rt:perform(c:put_op(42))
  end)
  local status = rt:run()
  return status.tag, value
end
local at, av = scenario('ledger')
local bt, bv = scenario('reference')
eq(at, bt, 'machines disagree on status')
eq(av, bv, 'machines disagree on value')

print('tests/test_performance_architecture.lua: ok')

-- Symmetry is never inferred.  Explicit certificates allow a failed
-- representative supplier to exclude the remaining interchangeable suppliers.
local function symmetric_failure(machine, enabled)
  local rt = Runtime.new({
    machine = machine,
    instrumentation = true,
    certified_symmetry = enabled,
    plan_reuse = false,
    dependency_index_threshold = 1,
  })
  local channel = Rendezvous.new('certified-symmetry-' .. machine)
  local cell = Cell.new(0, 'certified-symmetry-state-' .. machine)
  for _ = 1, 8 do
    rt:spawn_raw(function()
      rt:perform(channel:put_op(1):certify_symmetry('equivalent-producer'))
    end)
  end
  rt:spawn_raw(function()
    rt:perform(Op.tensor({ channel:get_op(), cell:write_op(1), cell:write_op(2) }))
  end)
  eq(rt:run().tag, 'quiescent')
  return rt:instrumentation_report().counters
end

for _, machine in ipairs({ 'ledger', 'reference' }) do
  local ordinary = symmetric_failure(machine, false)
  local certified = symmetric_failure(machine, true)
  truthy((certified.symmetry_supplier_pruned or 0) > 0, 'certified supplier symmetry was not used')
  truthy(
    (certified.search_calls or math.huge) * 2 < (ordinary.search_calls or 0),
    'certified symmetry did not materially reduce repeated supplier worlds'
  )
end

-- Static blocked plans are reusable across driver cycles, but a relevant store
-- change must invalidate the prior refutation.
local function repeated_blocked_run(machine, reuse)
  local rt = Runtime.new({
    machine = machine,
    instrumentation = true,
    plan_reuse = reuse,
    plan_reuse_threshold = 1,
  })
  for i = 1, 8 do
    local channel = Rendezvous.new('reuse-' .. machine .. '-' .. tostring(i))
    rt:spawn_raw(function()
      rt:perform(channel:get_op())
    end)
  end
  eq(rt:run().tag, 'quiescent')
  local first = rt:instrumentation_report().counters.search_calls or 0
  eq(rt:run().tag, 'quiescent')
  local counters = rt:instrumentation_report().counters
  return first, counters.search_calls or 0, counters
end

for _, machine in ipairs({ 'ledger', 'reference' }) do
  local off_first, off_second = repeated_blocked_run(machine, false)
  local on_first, on_second, counters = repeated_blocked_run(machine, true)
  truthy(off_second > off_first, 'control run did not repeat planning')
  eq(on_second, on_first, 'unchanged static plans were searched again')
  truthy((counters.plan_reuse_refutation_hits or 0) > 0, 'cross-cycle refutation reuse did not hit')
end

local invalidation = Runtime.new({ instrumentation = true, plan_reuse_threshold = 1 })
local invalidation_cell = StateMachine.new(0, 'reuse-invalidation')
local observed = false
invalidation:spawn_raw(function()
  observed = invalidation:perform(invalidation_cell:expect_op(1))
end)
eq(invalidation:run().tag, 'quiescent')
invalidation:spawn_raw(function()
  invalidation:perform(invalidation_cell:write_op(1))
end)
local invalidation_status
repeat
  invalidation_status = invalidation:run()
until invalidation_status.tag ~= 'found'
truthy(observed, 'relevant location change did not invalidate a cached certificate')

-- Per-focus certificates avoid repeated proof search without retaining complete
-- sessions or a component coordinator.
do
  local rt = Runtime.new({ machine = 'ledger', instrumentation = true, plan_reuse_threshold = 1 })
  local cell = StateMachine.new(0, 'per-focus-certificate-retry')
  for i = 1, 8 do
    rt:spawn_raw(function()
      rt:perform(cell:expect_op(1))
    end, 'per-focus-certificate-' .. tostring(i))
  end
  eq(rt:run().tag, 'quiescent')
  local first = rt:instrumentation_report().counters.search_calls or 0
  eq(rt:run().tag, 'quiescent')
  local counters = rt:instrumentation_report().counters
  eq(counters.search_calls or 0, first, 'unchanged certificates repeated focus search')
  truthy((counters.plan_reuse_refutation_hits or 0) >= 8, 'per-focus certificates were not reused')
end

print('tests/test_performance_architecture.lua: remaining performance passes ok')

-- Cross-cycle reuse is deliberately unavailable when an opaque continuation
-- can change without a versioned dependency stamp.
for _, machine in ipairs({ 'ledger', 'reference' }) do
  local rt = Runtime.new({
    machine = machine,
    instrumentation = true,
    plan_reuse_threshold = 1,
  })
  local channel = Rendezvous.new('opaque-cache-' .. machine)
  local opaque = channel:get_op():and_then(function(value)
    return Op.always(value)
  end)
  local alternatives = {}
  for i = 1, 16 do
    alternatives[i] = opaque
  end
  rt:spawn_raw(function()
    rt:perform(Op.choice(alternatives))
  end)
  eq(rt:run().tag, 'quiescent')
  local counters = rt:instrumentation_report().counters
  eq(counters.plan_reuse_stores or 0, 0, 'opaque continuation entered cross-cycle plan cache')
  truthy(
    (counters.plan_reuse_ineligible_dynamic or 0) > 0,
    'opaque continuation was not identified as dynamically ineligible'
  )
end

-- The lazy driver no longer stores positive candidates merely to survive the
-- gap between fibre admission and the ordinary focus pass.  A binary exchange
-- is proved only after both attempts are visible and is committed immediately.
for _, machine in ipairs({ 'ledger', 'reference' }) do
  local rt = Runtime.new({ machine = machine, instrumentation = true, plan_reuse_threshold = 1 })
  local channel = Rendezvous.new('lazy-positive-' .. machine)
  local value
  rt:spawn_raw(function()
    value = rt:perform(channel:get_op())
  end)
  rt:spawn_raw(function()
    rt:perform(channel:put_op(7))
  end)
  eq(rt:run().tag, 'found')
  eq(value, 7)
  local counters = rt:instrumentation_report().counters
  eq(counters.plan_reuse_candidate_hits or 0, 0, 'positive candidate cache should be unused')
  truthy((counters.plans or math.huge) <= 2, 'binary exchange was planned redundantly')
end

-- A new matching participant changes the component stamp and invalidates a
-- previously reusable blocked refutation.
for _, machine in ipairs({ 'ledger', 'reference' }) do
  local rt = Runtime.new({ machine = machine, instrumentation = true, plan_reuse_threshold = 1 })
  local channel = Rendezvous.new('frontier-invalidation-' .. machine)
  local value
  rt:spawn_raw(function()
    value = rt:perform(channel:get_op())
  end)
  eq(rt:run().tag, 'quiescent')
  rt:spawn_raw(function()
    rt:perform(channel:put_op(11))
  end)
  eq(rt:run().tag, 'found')
  eq(value, 11)
  truthy(
    (rt:instrumentation_report().counters.plan_reuse_invalidations or 0) > 0,
    'frontier change did not invalidate the cached certificate'
  )
end

print('tests/test_performance_architecture.lua: cache safety and invalidation ok')

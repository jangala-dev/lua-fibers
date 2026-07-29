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

local Runtime = require('fibers.runtime')
local Rendezvous = require('fibers.resource.rendezvous')
local Op = require('fibers.op')
local StateMachine = require('fibers.resource.machine')

local function truthy(value, message)
  if not value then
    error(message or 'expected truthy value', 2)
  end
end

local function eq(actual, expected, message)
  if actual ~= expected then
    error(
      (message or 'values differ') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual),
      2
    )
  end
end

local plain = Runtime.new()
eq(plain:instrumentation_report(), nil, 'instrumentation should be opt-in')

local rt = Runtime.new({ instrumentation = { trace = true, trace_limit = 32, slow_plan_limit = 4 } })
local ch = Rendezvous.new('instrumentation-test')
local got
rt:spawn_raw(function()
  got = rt:perform(ch:get_op())
end, 'instrumented-get')
rt:spawn_raw(function()
  rt:perform(ch:put_op('ok'))
end, 'instrumented-put')
local status = rt:run()
eq(status.tag, 'found')
eq(got, 'ok')

local snap = rt:instrumentation_report()
truthy(snap and snap.counters, 'missing instrumentation snapshot')
truthy((snap.counters.plans or 0) > 0, 'plans were not recorded')
if rt.machine_name ~= 'reference' then
  truthy(
    (snap.counters.search_sessions or 0) == (snap.counters.plans or -1),
    'each production plan should own one search session'
  )
else
  eq(snap.counters.search_sessions or 0, 0, 'reference plans should not create production sessions')
end
truthy((snap.counters.search_calls or 0) > 0, 'search calls were not recorded')
truthy((snap.counters.commits or 0) > 0, 'commits were not recorded')
truthy((snap.counters.fibres_spawned or 0) == 2, 'fibre creation count is wrong')
truthy((snap.maxima.pending_requests or 0) >= 1, 'pending request high-water mark missing')
truthy(#(snap.slow_plans or {}) > 0, 'slow-plan summaries missing')
truthy((snap.slow_plans[1].search_steps or 0) > 0, 'slow-plan search steps missing')
truthy(type(snap.histograms.search_steps_per_plan) == 'table', 'search histogram missing')
if rt.machine_name ~= 'reference' then
  truthy((snap.counters.option_nodes or 0) > 0, 'option graph shape was not recorded')
  truthy(type(snap.histograms.option_nodes_per_plan) == 'table', 'option-node histogram missing')
  truthy((snap.counters.dependency_exchanges or 0) > 0, 'exchange dependencies were not recorded')
end

rt:reset_instrumentation()
local empty = rt:instrumentation_report()
eq(empty.counters.plans, nil, 'reset did not clear counters')
eq(#empty.slow_plans, 0, 'reset did not clear slow plans')

-- Independent non-supplying machine-transition groups have no semantic
-- alternative. The one lazy machine should normalise them without introducing
-- claim branch frames.
local ForcedTransition = StateMachine.isolated_update(
  'instrumentation.forced_transition',
  function(_, payload)
    return StateMachine.Ready.write(payload, true)
  end
)
local forced_rt = Runtime.new({ machine = 'ledger', instrumentation = true })
local forced_a = StateMachine.new(0, 'instrumentation-forced-a')
local forced_b = StateMachine.new(0, 'instrumentation-forced-b')
forced_rt:spawn_raw(function()
  forced_rt:perform(Op.each({
    forced_a:transition_op(ForcedTransition, 1),
    forced_b:transition_op(ForcedTransition, 2),
  }))
end, 'forced-claims')
eq(forced_rt:run().tag, 'found')
eq(forced_a.value, 1)
eq(forced_b.value, 2)
local forced_snap = forced_rt:instrumentation_report()
truthy((forced_snap.counters.forced_claims or 0) >= 2, 'unavoidable claims were not normalised')
eq(forced_snap.counters.claim_branches or 0, 0, 'unavoidable claims opened branch frames')

-- Requests whose static footprints cannot satisfy the current intent must not
-- be recruited merely to enumerate irrelevant include/exclude subsets.
local pruned = Runtime.new({ machine = 'ledger', instrumentation = true })
for i = 1, 20 do
  local unrelated = Rendezvous.new('instrumentation-unrelated-' .. tostring(i))
  pruned:spawn_raw(function()
    pruned:perform(unrelated:get_op())
  end, 'unrelated-get-' .. tostring(i))
end
local pruned_status = pruned:run()
eq(pruned_status.tag, 'quiescent', 'unrelated requests should remain quiescent')
local pruned_snap = pruned:instrumentation_report()
eq(pruned_snap.maxima.search_steps_per_plan, 1, 'irrelevant recruitment should be pruned at the root')
eq(pruned_snap.counters.recruit_branches, 0, 'irrelevant roots were recruited')
eq(pruned_snap.counters.footprint_matches or 0, 0, 'unrelated footprints should not match')
truthy((pruned_snap.counters.component_roots_excluded or 0) > 0, 'component isolation was not exercised')
truthy((pruned_snap.maxima.component_size or 20) < 20, 'unrelated requests were never partitioned')

-- With component isolation disabled, the older footprint filter remains a
-- separately testable and supported safety net.
local legacy_pruned = Runtime.new({ machine = 'ledger', component_search = false, instrumentation = true })
for i = 1, 5 do
  local unrelated = Rendezvous.new('instrumentation-legacy-unrelated-' .. tostring(i))
  legacy_pruned:spawn_raw(function()
    legacy_pruned:perform(unrelated:get_op())
  end, 'legacy-unrelated-' .. tostring(i))
end
eq(legacy_pruned:run().tag, 'quiescent')
local legacy_snap = legacy_pruned:instrumentation_report()
eq(legacy_snap.counters.recruit_branches, 0, 'legacy footprint pruning recruited unrelated roots')
truthy((legacy_snap.counters.footprint_checks or 0) > 0, 'legacy footprint pruning was not exercised')

print('tests/test_instrumentation.lua: ok')

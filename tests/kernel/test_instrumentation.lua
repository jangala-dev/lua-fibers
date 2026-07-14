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
eq(plain:instrumentation_snapshot(), nil, 'instrumentation should be opt-in')

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

local snap = rt:instrumentation_snapshot()
truthy(snap and snap.counters, 'missing instrumentation snapshot')
truthy((snap.counters.plans or 0) > 0, 'plans were not recorded')
if rt.machine_name == 'trail' then
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

rt:reset_instrumentation()
local empty = rt:instrumentation_snapshot()
eq(empty.counters.plans, nil, 'reset did not clear counters')
eq(#empty.slow_plans, 0, 'reset did not clear slow plans')

-- Requests whose static footprints cannot satisfy the current intent must not
-- be recruited merely to enumerate irrelevant include/exclude subsets.
local pruned = Runtime.new({ machine = 'trail', instrumentation = true })
for i = 1, 20 do
  local unrelated = Rendezvous.new('instrumentation-unrelated-' .. tostring(i))
  pruned:spawn_raw(function()
    pruned:perform(unrelated:get_op())
  end, 'unrelated-get-' .. tostring(i))
end
local pruned_status = pruned:run()
eq(pruned_status.tag, 'quiescent', 'unrelated requests should remain quiescent')
local pruned_snap = pruned:instrumentation_snapshot()
eq(pruned_snap.maxima.search_steps_per_plan, 1, 'irrelevant recruitment should be pruned at the root')
eq(pruned_snap.counters.recruit_branches, 0, 'irrelevant roots were recruited')
eq(pruned_snap.counters.footprint_matches or 0, 0, 'unrelated footprints should not match')
truthy((pruned_snap.counters.component_roots_excluded or 0) > 0, 'component isolation was not exercised')
truthy((pruned_snap.maxima.component_size or 20) < 20, 'unrelated requests were never partitioned')

-- With component isolation disabled, the older footprint filter remains a
-- separately testable and supported safety net.
local legacy_pruned = Runtime.new({ machine = 'trail', component_search = false, instrumentation = true })
for i = 1, 5 do
  local unrelated = Rendezvous.new('instrumentation-legacy-unrelated-' .. tostring(i))
  legacy_pruned:spawn_raw(function()
    legacy_pruned:perform(unrelated:get_op())
  end, 'legacy-unrelated-' .. tostring(i))
end
eq(legacy_pruned:run().tag, 'quiescent')
local legacy_snap = legacy_pruned:instrumentation_snapshot()
eq(legacy_snap.counters.recruit_branches, 0, 'legacy footprint pruning recruited unrelated roots')
truthy((legacy_snap.counters.footprint_checks or 0) > 0, 'legacy footprint pruning was not exercised')

print('tests/test_instrumentation.lua: ok')

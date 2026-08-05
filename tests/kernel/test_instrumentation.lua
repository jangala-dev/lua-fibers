package.path = table.concat({
  './src/?.lua', './src/?/init.lua', './src/?/?.lua',
  './?.lua', './?/init.lua', './?/?.lua', package.path,
}, ';')

local Runtime = require('fibers.runtime')
local Rendezvous = require('fibers.resource.rendezvous')
local Op = require('fibers.op')

local function truthy(value, message)
  if not value then error(message or 'expected truthy value', 2) end
end

local function eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'values differ') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual), 2)
  end
end

local plain = Runtime.new()
eq((plain.instrumentation and plain.instrumentation:report()), nil, 'instrumentation should be opt-in')

local rt = Runtime.new({ instrumentation = { slow_search_limit = 4 } })
local channel = Rendezvous.new():label('instrumentation-test')
local got
rt:spawn_raw(function() got = rt:perform(channel:get_op():label('instrumented-get-op')) end):label('instrumented-get')
rt:spawn_raw(function() rt:perform(channel:put_op('ok'):label('instrumented-put-op')) end):label('instrumented-put')
eq(rt:run().tag, 'found')
eq(got, 'ok')

local snap = (rt.instrumentation and rt.instrumentation:report())
truthy(snap and snap.counters, 'missing instrumentation snapshot')
truthy((snap.counters.searches or 0) > 0, 'searches were not recorded')
truthy((snap.counters.search_calls or 0) >= 0, 'search-call counter is invalid')
truthy((snap.counters.commits or 0) > 0, 'commits were not recorded')
eq(snap.counters.fibers_spawned, 2, 'fiber creation count is wrong')
truthy((snap.maxima.pending_requests or 0) >= 1, 'pending request high-water mark missing')
truthy(#(snap.slow_searches or {}) > 0, 'slow-search summaries missing')
local labelled_search
for i = 1, #(snap.slow_searches or {}) do
  local row = snap.slow_searches[i]
  if row.operation_label and row.fiber_label then
    labelled_search = row
    break
  end
end
truthy(labelled_search, 'search summaries should retain option and fiber labels')
truthy(type(snap.histograms.search_steps_per_search) == 'table', 'search histogram missing')

rt.instrumentation:reset()
local empty = (rt.instrumentation and rt.instrumentation:report())
eq(empty.counters.searches, nil, 'reset did not clear counters')
eq(#empty.slow_searches, 0, 'reset did not clear slow searchs')

-- Bounded work creates retained sessions; an unbounded direct hit need not.
local bounded = Runtime.new({ instrumentation = true })
local value
bounded:spawn_raw(function()
  value = bounded:perform(Op.choice(Op.always('a'), Op.always('b')))
end):label('bounded-instrumentation')
for _ = 1, 20 do
  local status = bounded:step({ max_work = 1 })
  if status.tag == 'found' then break end
end
bounded:run()
truthy(value == 'a' or value == 'b')
local bounded_snap = (bounded.instrumentation and bounded.instrumentation:report())
truthy((bounded_snap.counters.retained_search_stores or 0) >= 1, 'bounded session was not retained')
truthy((bounded_snap.counters.retained_search_resumes or 0) >= 1, 'bounded session was not resumed')

print('tests/kernel/test_instrumentation.lua: ok')

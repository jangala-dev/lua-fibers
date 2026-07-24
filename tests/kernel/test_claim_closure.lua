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

local Counter = require('fibers.resource.counter')
local Index = require('fibers.resource.index')
local Op = require('fibers.op')
local Facility = require('fibers.resource.authoring')
local Program = require('fibers.internal.kernel.ir')
local Runtime = require('fibers.runtime')

local function eq(actual, expected, message)
  if actual ~= expected then
    error(
      (message or 'values differ') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual),
      2
    )
  end
end

local function truthy(value, message)
  if not value then
    error(message or 'expected truthy value', 2)
  end
end

-- The closure candidate should discover a direct same-location hand-off
-- without requiring a fixed source-order guess.
local rt = Runtime.new({ instrumentation = true })
local index = Index.new({}, 'claim-closure-index')
local rows
rt:spawn_raw(function()
  rows = rt:perform(Op.tensor({
    index:pop_first_op(),
    index:append_op('value'),
  }))
end, 'claim-closure-handoff')

eq(rt:run().tag, 'found')
eq(rows[1][1].value, 'value')
eq(rows[2][1], true)

local snap = rt:instrumentation_snapshot()
if rt.machine_name == 'ledger' then
  truthy((snap.counters.claim_closure_branches or 0) > 0, 'closure branch was not offered')
  truthy((snap.counters.claim_closure_successes or 0) > 0, 'closure did not discover the hand-off')
end

-- A closure is only the first candidate.  If its ready-first serialisation
-- fails, the same machine must retain singleton alternatives and discover a
-- different valid order.
local backtrack_rt = Runtime.new({ instrumentation = true })
local counter = Counter.new({ initial = 1, min = 0 }, 'claim-closure-counter')
local observe_positive = Facility.op(
  counter,
  Counter.Kind,
  Facility.claim({
    location = counter._location,
    group = counter,
    demand = 'up',
    query = { kind = 'predicate', predicate = 'ge', threshold = 1 },
    result = Facility.result.boolean,
  })
)
local backtrack_rows
backtrack_rt:spawn_raw(function()
  backtrack_rows = backtrack_rt:perform(Op.tensor({
    counter:take_op(1),
    observe_positive,
  }))
end, 'claim-closure-backtrack')

eq(backtrack_rt:run().tag, 'found')
eq(backtrack_rows[1][1], true)
eq(backtrack_rows[2][1], true)
eq(counter.value, 0)

local backtrack_snap = backtrack_rt:instrumentation_snapshot()
if backtrack_rt.machine_name == 'ledger' then
  truthy((backtrack_snap.counters.claim_closure_failures or 0) > 0, 'failed closure was not observed')
  truthy((backtrack_snap.counters.claim_single_branches or 0) > 0, 'singleton alternatives were not retained')
end

return true

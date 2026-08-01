package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

local Counter = require('fibers.resource.counter')
local Index = require('fibers.resource.index')
local Op = require('fibers.op')
local Facility = require('fibers.resource.authoring')
local Runtime = require('fibers.runtime')

local function eq(actual, expected, message)
  if actual ~= expected then
    error(
      (message or 'values differ') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual),
      2
    )
  end
end


-- The closure candidate should discover a direct same-location hand-off
-- without requiring a fixed source-order guess.
local rt = Runtime.new({ instrumentation = true })
local index = Index.new('claim-closure-index')
local rows
rt:spawn_raw(function()
  rows = rt:perform(Op.together({
    index:pop_first_op(),
    index:append_op('value'),
  }))
end, 'claim-closure-handoff')

eq(rt:run().tag, 'found')
eq(rows[1][1].value, 'value')
eq(rows[2][1], true)


-- A closure is only the first candidate.  If its ready-first serialisation
-- fails, the same machine must retain singleton alternatives and discover a
-- different valid order.
local backtrack_rt = Runtime.new({ instrumentation = true })
local counter = Counter.new(1, 'claim-closure-counter')
local observe_positive = Facility.op(Facility.rule.inspect({
    location = counter._location,
    resource = counter,
    demand = 'up',
    visibility = 'together',
    step = function(value)
      if value < 1 then return nil end
      return Facility.outcome(nil, true)
    end,
  })
)
local backtrack_rows
backtrack_rt:spawn_raw(function()
  backtrack_rows = backtrack_rt:perform(Op.together({
    counter:take_op(1),
    observe_positive,
  }))
end, 'claim-closure-backtrack')

eq(backtrack_rt:run().tag, 'found')
eq(backtrack_rows[1][1], true)
eq(backtrack_rows[2][1], true)
eq(counter.value, 0)


return true

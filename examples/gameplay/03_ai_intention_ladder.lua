package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

-- The guard captain attacks when an attack is viable, otherwise takes cover,
-- otherwise patrols. Fallback is based on managed facts, not on whichever
-- branch happens to run fastest.

local fibers = require('fibers')
local Op = require('fibers.op')
local Cell = require('fibers.resource.cell')

local intruder_visible = Cell.new(false, 'intruder-visible')
local cover_available = Cell.new(true, 'cover-available')
local first_decision, second_decision

local function choose_intention_op()
  local attack = intruder_visible:expect_op(true):map(function()
    return 'raise the alarm and intercept'
  end)

  local take_cover = cover_available:expect_op(true):map(function()
    return 'take cover and watch the eastern stair'
  end)

  return attack:or_else(take_cover):or_else(Op.always('resume the lantern patrol'))
end

fibers.run(function()
  first_decision = fibers.perform(choose_intention_op())
  intruder_visible:write(true)
  second_decision = fibers.perform(choose_intention_op())
end)

assert(first_decision == 'take cover and watch the eastern stair')
assert(second_decision == 'raise the alarm and intercept')
print('before sighting:', first_decision)
print('after sighting:', second_decision)

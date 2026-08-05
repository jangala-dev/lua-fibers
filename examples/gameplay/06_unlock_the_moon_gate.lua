package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

-- The silver key is consumed only if the gate can change from locked to open in
-- the same committed world. Repeating the mechanic falls back without losing
-- another item.

local fibers = require('fibers')
local Op = require('fibers.op')
local Counter = require('fibers.resource.counter')
local Cell = require('fibers.resource.cell')

local silver_keys = Counter.new(1):label('silver-keys')
local moon_gate = Cell.new('locked'):label('moon-gate')
local first, second

local function unlock_op()
  return Op.each({
    silver_keys:take_op(1),
    moon_gate:expect_op('locked'),
  })
    :and_then(moon_gate:write_op('open'):map(function()
        return 'the Moon Gate opened'
      end))
    :or_else(Op.always('the gate remains as it is'))
end

fibers.run(function()
  first = fibers.perform(unlock_op())
  second = fibers.perform(unlock_op())
end)

assert(first == 'the Moon Gate opened')
assert(second == 'the gate remains as it is')
assert(silver_keys.value == 0)
assert(moon_gate.value == 'open')
print(first)
print(second)

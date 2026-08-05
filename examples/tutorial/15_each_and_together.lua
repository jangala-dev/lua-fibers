package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

-- each requires every lane to stand on its own. together permits intentional
-- sibling support: one lane writes a control word which another lane reads
-- within the same committed world.

local fibers = require('fibers')
local Op = require('fibers.op')
local Counter = require('fibers.resource.counter')
local Flow = require('fibers.resource.flow')

local motor_channels = Counter.new(1):label('motor-channels')
local vision_channels = Counter.new(1):label('vision-channels')
local control_bus = Flow.new(16):label('robot-control-bus')

fibers.run(function()
  fibers.perform(Op.each({
    motor_channels:take_op(1),
    vision_channels:take_op(1),
  }))

  local rows = fibers.perform(Op.together({
    control_bus:inlet():write_op('GO'),
    control_bus:outlet():read_some_op(2),
  }))

  assert(rows[1][1] == 2)
  assert(rows[2][1] == 'GO')
end)

assert(motor_channels.value == 0 and vision_channels.value == 0)
print('each reserved motor and vision; together handed off GO')

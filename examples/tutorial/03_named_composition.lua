package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

-- Named combinators retain the language of the decision in its result.

local fibers = require('fibers')
local Op = require('fibers.op')
local Sleep = require('fibers.sleep')
local channel = require('fibers.channel')
local ManualHost = require('fibers.embed.manual')

local position_fixes = channel.new()
local selected, position, drive_ready, transfer

fibers.run(function(scope)
  scope:spawn(function()
    position_fixes:put('aisle 7, bay 3')
  end):label('vision-localiser')

  selected, position = fibers.perform(Op.named_choice({
    vision = position_fixes:get_op(),
    dead_reckoning = Sleep.sleep_op(5):map(function()
      return 'estimated from wheel odometry'
    end),
  }))

  local readiness = fibers.perform(Op.named_each({
    motors = Op.always('armed'),
    lidar = Op.always('clear'),
  }))
  drive_ready = readiness.motors .. ' and ' .. readiness.lidar

  transfer = fibers.perform(Op.named_together({
    source = Op.always('battery'),
    destination = Op.always('drive'),
  }))
end, { host = ManualHost.new() })

assert(selected == 'vision')
assert(position == 'aisle 7, bay 3')
assert(drive_ready == 'armed and clear')
assert(transfer.source == 'battery' and transfer.destination == 'drive')
print('localisation:', selected, position)
print('drive:', drive_ready)

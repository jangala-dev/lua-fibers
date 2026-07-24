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
local Host = require('fibers.host')

local position_fixes = channel.new()
local selected, position, drive_ready

fibers.run(function(scope)
  scope:spawn(function()
    position_fixes:put('aisle 7, bay 3')
  end, 'vision-localiser')

  selected, position = fibers.perform(Op.named_choice({
    vision = position_fixes:get_op(),
    dead_reckoning = Sleep.sleep_op(5):map(function()
      return 'estimated from wheel odometry'
    end),
  }))

  local readiness = fibers.perform(Op.named_all({
    motors = Op.always('armed'),
    lidar = Op.always('clear'),
  }))
  drive_ready = readiness.motors .. ' and ' .. readiness.lidar
end, { host = Host.manual() })

assert(selected == 'vision')
assert(position == 'aisle 7, bay 3')
assert(drive_ready == 'armed and clear')
print('localisation:', selected, position)
print('drive:', drive_ready)

package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

-- Tasks belong to a scope. A firmware start-up boundary accounts for sensor
-- calibration and radio configuration before the controller proceeds.

local fibers = require('fibers')

local sensor, radio

fibers.run(function(scope)
  local sensor_task = scope:spawn(function()
    return 'temperature sensor calibrated'
  end, 'calibrate-temperature-sensor')

  local radio_task = scope:spawn(function()
    return 'mesh radio configured'
  end, 'configure-mesh-radio')

  sensor = sensor_task:await()
  radio = radio_task:await()
end)

assert(sensor == 'temperature sensor calibrated')
assert(radio == 'mesh radio configured')
print('controller ready:', sensor, 'and', radio)

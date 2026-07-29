package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

-- Keep one absolute deadline across several firmware start-up stages. Starting
-- a fresh relative timeout for every device would silently extend the allowed
-- boot window.

local fibers = require('fibers')
local Op = require('fibers.op')
local Sleep = require('fibers.sleep')
local ManualHost = require('fibers.embed.manual')

local sensor_stage, radio_stage, finished_at

fibers.run(function()
  local boot_deadline = fibers.now() + 3

  sensor_stage = fibers.perform(Op.named_choice({
    ready = Sleep.sleep_op(1):map(function()
      return 'sensor calibrated'
    end),
    timeout = Sleep.sleep_until_op(boot_deadline):map(function()
      return 'boot deadline reached'
    end),
  }))

  radio_stage = fibers.perform(Op.named_choice({
    ready = Sleep.sleep_op(3):map(function()
      return 'radio joined mesh'
    end),
    timeout = Sleep.sleep_until_op(boot_deadline):map(function()
      return 'boot deadline reached'
    end),
  }))

  finished_at = fibers.now()
end, { host = ManualHost.new() })

assert(sensor_stage == 'ready')
assert(radio_stage == 'timeout')
assert(finished_at == 3)
print('firmware start-up:', sensor_stage, radio_stage, 'finished at:', finished_at)

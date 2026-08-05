package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

-- and_then carries a provisional result into the next option. Reserving the
-- last satellite uplink slot and admitting a clinic session form one transaction.

local fibers = require('fibers')
local channel = require('fibers.channel')
local Counter = require('fibers.resource.counter')

local uplink_slots = Counter.new(1):label('satellite-uplink-slots')
local telemetry_sessions = channel.new()
local admitted_clinic, outcome

fibers.run(function(scope)
  scope:spawn(function()
    admitted_clinic = telemetry_sessions:get()
  end):label('telemetry-router')

  outcome = fibers.perform(uplink_slots
    :take_op(1)
    :and_then(telemetry_sessions:put_op('clinic-7'))
    :map(function()
      return 'telemetry admitted'
    end))
end)

assert(outcome == 'telemetry admitted')
assert(admitted_clinic == 'clinic-7')
assert(uplink_slots.value == 0)
print('field network:', outcome, '-', admitted_clinic)

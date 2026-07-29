package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

-- The same language serves Jangala's original field-system concerns: reserve
-- power, confirm safety and dispatch a connected unit as one coherent plan.

local fibers = require('fibers')
local Op = require('fibers.op')
local channel = require('fibers.channel')
local Cell = require('fibers.resource.cell')
local Counter = require('fibers.resource.counter')

local perform = fibers.perform
local spawn = fibers.spawn

local function mission_op(field_unit, mission)
  return field_unit.online:expect_op(true):and_then(function()
    return field_unit.commands:put_op(mission):and_then(function()
      return field_unit.reports:get_op()
    end)
  end)
end

local unit_is_online = true
local outcome

fibers.run(function()
  local field_unit = {
    online = Cell.new(unit_is_online, 'water-survey-unit:online'),
    commands = channel.new(),
    reports = channel.new(),
  }
  local stop_requests = channel.new()
  local safety_interlock = Cell.new('clear', 'deployment-safety')
  local battery_reserve = Counter.new(1, 'battery-reserve')

  if unit_is_online then
    spawn(function()
      perform(field_unit.commands:get_op():and_then(function(mission)
        return field_unit.reports:put_op('completed ' .. mission)
      end))
    end, 'water-survey-unit')
  end

  local dispatch = Op.all({
    safety_interlock:expect_op('clear'),
    battery_reserve:take_op(1),
  })
    :and_then(function()
      return mission_op(field_unit, 'survey the eastern water point')
    end)
    :or_else(Op.always('field dispatch unavailable'))

  local stop = stop_requests:get_op():map(function(reason)
    return 'stopped: ' .. reason
  end)

  outcome = perform(Op.choice(dispatch, stop):wrap(function(message)
    print(message)
    return message
  end))
end)

assert(
  outcome == (unit_is_online and 'completed survey the eastern water point' or 'field dispatch unavailable')
)

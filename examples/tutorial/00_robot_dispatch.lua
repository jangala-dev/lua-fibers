package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

local fibers = require('fibers')
local channel = require('fibers.channel')
local Scalar = require('fibers.scalar')
local Counter = require('fibers.resource.counter')

local perform = fibers.perform
local spawn = fibers.spawn
local choice = fibers.choice
local all = fibers.all
local always = fibers.always

local function call_op(robot, command)
  return robot.online:expect_op(true):and_then(function()
    return robot.requests:put_op(command):and_then(function()
      return robot.replies:get_op()
    end)
  end)
end

local online = true
local result

fibers.run(function()
  local robot = {
    online = Scalar.new(online, 'robot:online'),
    requests = channel.new(),
    replies = channel.new(),
  }
  local stop = channel.new()
  local safety = Scalar.new('clear', 'safety')
  local power = Counter.new({ initial = 1, name = 'power' })

  if online then
    spawn(function()
      perform(robot.requests:get_op():and_then(function(command)
        return robot.replies:put_op('completed ' .. command)
      end))
    end, 'robot')
  end

  result = perform(choice(
    all({
      safety:expect_op('clear'),
      power:take_op(1),
    }):and_then(function()
      return call_op(robot, 'inspection')
    end):or_else(always('dispatch unavailable')),

    stop:get_op():map(function(reason)
      return 'stopped: ' .. reason
    end)
  ):wrap(function(message)
    print(message)
    return message
  end))
end)

assert(result == (online and 'completed inspection' or 'dispatch unavailable'))

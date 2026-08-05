package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

-- Externally fed resources: outside facts entering the option algebra.
--
-- This example uses Signal and Clock resources with an explicit Runtime so the
-- host remains in control of time and stepping.

local External = require('fibers.embed.external')
local fibers = require('fibers')
local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local Clock = require('fibers.resource.clock')
local now = 0
local rt = Runtime.new({ host = {
  now = function()
    return now
  end,
} })

local clock = Clock.new():label('clock')
local signal, signal_feed = External.signal(rt)
signal:label('reload-signal')
local result

rt:spawn_raw(function()
  result = rt:perform(Op.choice(
    signal:wait_op():map(function(value)
      return 'signal: ' .. tostring(value)
    end),
    clock:at_op(10):map(function()
      return 'timeout'
    end)
  ))
end):label('waiter')

local st = rt:run()
print('initial status:', st.tag)

signal_feed:set('reload requested')
st = rt:step()
print('after host event:', st.tag, result)

-- If the signal had not arrived, advancing host time to 10 would make the
-- clock branch commit instead.

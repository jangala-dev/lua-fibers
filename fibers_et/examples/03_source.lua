package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

-- Source: outside facts entering the operation algebra.
--
-- This example uses signal and clock sources with an explicit Runtime so the
-- host remains in control of time and stepping.

local fibers = require('fibers')

local now = 0
local rt = fibers.Runtime.new({ host = { now = function() return now end } })

local clock = fibers.Source.clock('clock')
local signal, signal_feed = rt:signal('reload-signal')
local result

rt:spawn_raw(function()
  result = rt:perform(fibers.choice(
    signal:wait_op():map(function(value)
      return 'signal: ' .. tostring(value)
    end),
    clock:at_op(10):map(function()
      return 'timeout'
    end)
  ))
end, 'waiter')

local st = rt:run()
print('initial status:', st.tag)

signal_feed:set('reload requested')
st = rt:step()
print('after host event:', st.tag, result)

-- If the signal had not arrived, advancing host time to 10 would make the
-- clock branch commit instead.

package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './reference/?.lua',
  './reference/?/init.lua',
  './reference/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

-- Externally fed resources: outside facts entering the option algebra.
--
-- This example uses Signal and Clock resources with an explicit Runtime so the
-- host remains in control of time and stepping.

local fibers = require('fibers')
local Runtime = require('fibers.runtime')
local Clock = require('fibers.external.clock')
local now = 0
local rt = Runtime.new({ host = {
  now = function()
    return now
  end,
} })

local clock = Clock.new('clock')
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

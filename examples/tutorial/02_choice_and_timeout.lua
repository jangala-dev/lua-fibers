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

-- Choice: compose a timeout and a channel receive as ordinary operations.

local fibers = require('fibers')
local channel = require('fibers.channel')
local host = require('fibers.host')

local my_chan = channel.new()
local retval
local eventual_message

fibers.run(function()
  fibers.spawn(function()
    fibers.perform(fibers.sleep_op(2):and_then(function()
      return my_chan:put_op('hello')
    end))
  end, 'delayed-sender')

  retval = fibers.perform(fibers.choice(
    fibers.sleep_op(1):wrap(function()
      return 'timeout'
    end),
    my_chan:get_op()
  ))

  -- Drain the delayed sender so the enclosing scope can finish normally.
  if retval == 'timeout' then
    eventual_message = fibers.perform(my_chan:get_op())
  end
end, { host = host.manual() })

assert(retval == 'timeout')
assert(eventual_message == 'hello')
print('choice result:', retval)

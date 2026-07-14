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

-- Channel: ordinary communication between scoped fibres.

local fibers = require('fibers')
local channel = require('fibers.channel')

local inbox = channel.new()
local received

fibers.run(function()
  fibers.spawn(function()
    fibers.perform(inbox:put_op('hello from another fibre'))
  end, 'sender')

  received = fibers.perform(inbox:get_op())
end)

print('received:', received)

package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

-- Channel: a synchronous meeting point.
--
-- A send and receive do not happen independently.  They rendezvous in one
-- committed transaction, and both fibres resume only after that commit.

local fibers = require('fibers')

local inbox = fibers.Channel.new('inbox')
local received

fibers.run(function()
  fibers.spawn_raw(function()
    fibers.perform(inbox:send_op('hello from another fibre'))
  end, 'sender')

  received = fibers.perform(inbox:recv_op())
end)

print('received:', received)

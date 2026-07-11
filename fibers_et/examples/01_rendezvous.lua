package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

-- Rendezvous: a synchronous meeting point.
--
-- A send and receive do not happen independently.  They rendezvous in one
-- committed transaction, and both fibres resume only after that commit.

local fibers = require('fibers')

local inbox = fibers.Rendezvous.new('inbox')
local received

fibers.run(function()
  fibers.spawn(function()
    fibers.perform(inbox:put_op('hello from another fibre'))
  end, 'sender')

  received = fibers.perform(inbox:get_op())
end)

print('received:', received)

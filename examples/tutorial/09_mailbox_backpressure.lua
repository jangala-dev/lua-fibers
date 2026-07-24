package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

-- Mailbox adds bounded buffering, close semantics and explicit full policies.
-- reject_newest reports overload without disturbing the value already queued.

local fibers = require('fibers')
local Mailbox = require('fibers.mailbox')

local first_ok, second_ok, second_reason
local first, third, closed, close_reason, dropped

fibers.run(function()
  local tx, rx = Mailbox.new({
    capacity = 1,
    full = 'reject_newest',
    name = 'work-mailbox',
  })

  first_ok = tx:send('first')
  second_ok, second_reason = tx:send('second')
  first = rx:recv()

  assert(tx:send('third'))
  tx:close('producer finished')

  third = rx:recv()
  closed, close_reason = rx:recv()
  dropped = fibers.perform(rx:dropped_op())
end)

assert(first_ok == true)
assert(second_ok == false and second_reason == 'full')
assert(first == 'first' and third == 'third')
assert(closed == nil and close_reason == 'producer finished')
assert(dropped == 1)
print('received:', first, third, 'rejected:', dropped)

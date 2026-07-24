package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

-- A plain method performs now. Its _op twin describes the same action without
-- performing it, so that it can later join a larger decision.

local fibers = require('fibers')
local channel = require('fibers.channel')

local inbox = channel.new()
local first, second

fibers.run(function(scope)
  scope:spawn(function()
    inbox:put('direct')
    inbox:put('composed')
  end, 'sender')

  first = inbox:get()

  local receive_later = inbox:get_op() -- inert until perform
  second = fibers.perform(receive_later)
end)

assert(first == 'direct')
assert(second == 'composed')
print('direct:', first, 'option:', second)

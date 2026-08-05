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

local status_updates = channel.new()
local first_update, second_update

fibers.run(function(scope)
  scope:spawn(function()
    status_updates:put('configuration loaded')
    status_updates:put('connection ready')
  end):label('status-source')

  first_update = status_updates:get()

  local receive_later = status_updates:get_op() -- inert until perform
  second_update = fibers.perform(receive_later)
end)

assert(first_update == 'configuration loaded')
assert(second_update == 'connection ready')
print('direct:', first_update)
print('option:', second_update)

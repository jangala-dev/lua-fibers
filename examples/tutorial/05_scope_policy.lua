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

local fibers = require('fibers')
local channel = require('fibers.channel')
local policy = require('fibers.policy')

local message
local child

fibers.run(function(scope)
  local ch = channel.new()

  child = fibers.spawn(function()
    fibers.perform(ch:put_op('hello from a structured task'))
  end, 'sender')

  message = fibers.perform(ch:get_op())

  -- The root scope admits tasks to its Region. On exit it seals the Region,
  -- waits for owned tasks, and settles remaining obligations.
  assert(scope:raw_region())
end, { policy = policy.nursery() })

assert(message == 'hello from a structured task')
assert(child.owner == nil)

print('05_scope_policy.lua: ok')

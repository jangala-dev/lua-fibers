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

local message
local child

fibers.run(function(scope)
  local ch = fibers.Rendezvous.new('nursery-example')

  child = fibers.spawn(function()
    fibers.perform(ch:put_op('hello from a structured task'))
  end, 'sender')

  message = fibers.perform(ch:get_op())

  -- The root scope admits tasks to its Region. On exit it seals the Region,
  -- waits for owned tasks, and settles remaining obligations.
  assert(scope:raw_region())
end, { policy = fibers.policy.nursery() })

assert(message == 'hello from a structured task')
assert(child.owner == nil)

print('06_policy_nursery.lua: ok')

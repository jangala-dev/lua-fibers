package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

-- Embedders deliver outside facts through runtime-bound feeds. Delivery occurs
-- outside a fibre; it invalidates the relevant proof frontier and wakes the
-- Fibers runtime.

local Runtime = require('fibers.runtime')
local Host = require('fibers.host')

local runtime = Runtime.new({ host = Host.manual() })
local signal, feed = runtime:signal('button')
local result

runtime:spawn_raw(function()
  result = runtime:perform(signal:wait_op())
end, 'button-waiter')

local initial = runtime:run()
assert(initial.tag == 'pending')

feed:set('pressed')
local resumed = runtime:run()

assert(resumed.tag == 'found')
assert(result == 'pressed')
print('initial:', initial.tag, 'after feed:', resumed.tag, result)

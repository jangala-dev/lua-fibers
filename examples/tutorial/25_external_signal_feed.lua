package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

-- Embedders deliver outside facts through runtime-bound feeds. A hardware
-- interrupt or host callback invalidates the relevant proof frontier and wakes
-- the Fibers runtime without running application logic re-entrantly.

local Runtime = require('fibers.runtime')
local ManualHost = require('fibers.embed.manual')

local runtime = Runtime.new({ host = ManualHost.new() })
local signal, feed = runtime:signal('door-sensor')
local result

runtime:spawn_raw(function()
  result = runtime:perform(signal:wait_op())
end, 'door-sensor-waiter')

local initial = runtime:run()
assert(initial.tag == 'pending')

feed:set('open')
local resumed = runtime:run()

assert(resumed.tag == 'found')
assert(result == 'open')
print('initial:', initial.tag, 'after sensor feed:', resumed.tag, result)

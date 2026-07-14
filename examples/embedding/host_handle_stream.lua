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
local Runtime = require('fibers.runtime')
local Region = require('fibers.lifetime.region')
local Stream = require('fibers.stream')
local Runner = require('fibers.runner')
local Host = require('fibers.host')
local host = Host.manual({ auto_advance_time = false })
local rt = Runtime.new({ host = host })
local region = Region.new('handle-example-region')
local handle = Host.Handle.fake({ host = host, key = 'example-handle' })

local stream, got, flushed

rt:spawn_raw(function()
  stream =
    rt:perform(Stream.open_handle_in_op(region, handle, { name = 'example-handle-stream' }))
  got = rt:perform(stream:reader():read_exactly_op(5))
  rt:perform(stream:writer():write_op('pong'))
  flushed = rt:perform(stream:writer():flush_op())
end, 'example-user')

-- The stream opens and then waits for the host handle to become readable.
Runner.run(rt, { host = host, max_iterations = 80 })
handle:feed_read('hello')

Runner.run(rt, { host = host, max_iterations = 80 })

assert(got == 'hello')
assert(flushed == true)
assert(handle:written() == 'pong')

print('examples/embedding/host_handle_stream.lua: ok')

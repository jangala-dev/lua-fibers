package.path = table.concat({'./?.lua','./?/init.lua','./?/?.lua',package.path}, ';')

local fibers = require('fibers')

local host = fibers.host.manual({ auto_advance_time = false })
local rt = fibers.Runtime.new({ host = host })
local region = fibers.Region.new('handle-example-region')
local handle = fibers.host.Handle.fake({ host = host, key = 'example-handle' })

local stream, got, flushed

rt:spawn_raw(function()
  stream = rt:perform(fibers.Stream.open_handle_in_op(region, handle, { name = 'example-handle-stream' }))
  got = rt:perform(stream:reader():read_exactly_op(5))
  rt:perform(stream:writer():write_op('pong'))
  flushed = rt:perform(stream:writer():flush_op())
end, 'example-user')

-- The stream opens and then waits for the host handle to become readable.
fibers.Runner.run(rt, { host = host, max_iterations = 80 })
handle:feed_read('hello')

fibers.Runner.run(rt, { host = host, max_iterations = 80 })

assert(got == 'hello')
assert(flushed == true)
assert(handle:written() == 'pong')

print('examples/14_host_handle_stream.lua: ok')

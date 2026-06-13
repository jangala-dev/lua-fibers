package.path = table.concat({'./?.lua','./?/init.lua','./?/?.lua',package.path}, ';')

local fibers = require('fibers')
local Stream = fibers.Stream

local rt = fibers.Runtime.new()
local region = fibers.Region.new('readiness-example')
local backend = Stream.backend.Fake.new({
  name = 'readiness-example-backend',
  readiness = 'manual',
  initial_writable = false,
  write_blocked = true,
})

local stream, line, flushed

rt:spawn_raw(function()
  stream = rt:perform(Stream.open_backend_op(region, backend, { name = 'readiness-example-stream' }))
  rt:perform(stream:write_op('ping\n'))
  flushed = rt:perform(stream:flush_op())
  line = rt:perform(stream:read_line_op())
end, 'root')

-- Opening commits stream ownership and pump tasks, but write readiness has not
-- arrived yet, so nothing has reached the backend.
rt:run()
assert(backend:written() == '')

-- A host adapter would call this when the handle becomes writable.
backend:unblock_writes()
rt:run()
assert(flushed == true)
assert(backend:written() == 'ping\n')

-- Host input is separate from readiness delivery.
backend:feed_read('pong\n')
backend:mark_readable()
rt:run()
assert(line == 'pong')

print('examples/12_readiness_stream.lua: ok')

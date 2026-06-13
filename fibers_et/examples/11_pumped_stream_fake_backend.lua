package.path = table.concat({'./?.lua','./?/init.lua','./?/?.lua',package.path}, ';')

local fibers = require('fibers')
local Stream = fibers.Stream
local Fake = Stream.backend.Fake

local rt = fibers.Runtime.new()
local region = fibers.Region.new('fake-host-region')
local backend = Fake.new({ name = 'fake-host', write_chunk_size = 2 })
local stream, line, flushed

rt:spawn_raw(function()
  stream = rt:perform(Stream.open_backend_op(region, backend, {
    name = 'fake-host-stream',
    read_capacity = 16,
    write_capacity = 16,
  }))

  line = rt:perform(stream:reader():read_line_op())
  rt:perform(stream:writer():write_op('echo:' .. line .. '\n'))
  flushed = rt:perform(stream:writer():flush_op())
  rt:perform(stream:writer():shutdown_op())
end, 'root')

-- Start the root and pump tasks.  The reader is now waiting for host input.
rt:run()
backend:feed_read('hello\n')

for _ = 1, 100 do
  if flushed and backend.shutdown_write_reason then break end
  rt:run()
end

assert(line == 'hello')
assert(flushed == true)
assert(backend:written() == 'echo:hello\n')
assert(backend.shutdown_write_reason ~= nil)

print('examples/11_pumped_stream_fake_backend.lua: ok')

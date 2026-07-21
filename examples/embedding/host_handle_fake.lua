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

local HostHandle = require('fibers.host.handle')

local rt = Runtime.new()
local region = Region.new('fake-host-region')
local handle = HostHandle.fake({ name = 'fake-host', write_chunk_size = 2 })
local stream, line, flushed

rt:spawn_raw(function()
  stream = rt:perform(Stream.open_op(handle, {
    owner = region,
    name = 'fake-host-stream',
    read = true,
    write = true,
    read_capacity = 16,
    write_capacity = 16,
  }))

  line = rt:perform(stream:reader():read_line_op())
  rt:perform(stream:writer():write_op('echo:' .. line .. '\n'))
  flushed = rt:perform(stream:writer():flush_op())
  rt:perform(stream:shutdown_write_op())
end, 'root')

-- Start the root and the runtime-owned reactor.  The reader is now waiting for host input.
rt:run()
handle:feed_read('hello\n')

for _ = 1, 100 do
  if flushed and handle.shutdown_write_reason then
    break
  end
  rt:run()
end

assert(line == 'hello')
assert(flushed == true)
assert(handle:written() == 'echo:hello\n')
assert(handle.shutdown_write_reason ~= nil)

print('examples/embedding/host_handle_fake.lua: ok')

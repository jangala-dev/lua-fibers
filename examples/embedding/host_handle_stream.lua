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

local Host = require('fibers.host')
local Region = require('fibers.region')
local fibers = require('fibers')
local Runtime = require('fibers.runtime')
local Stream = require('fibers.stream')

local host = Host.manual({ auto_advance_time = false })
local input, input_writer = Host.Handle.pipe_pair({ host = host, name = 'example-input' })
local output_reader, output = Host.Handle.pipe_pair({ host = host, name = 'example-output' })
local handle = Host.Handle.duplex(input, output, { host = host, name = 'example-duplex' })
local runtime = Runtime.new({ host = host })
local region = Region.new('handle-example-region')
local got, flushed

runtime:spawn_raw(function()
  local stream = runtime:perform(Stream.open_op(handle, {
    owner = region,
    name = 'example-handle-stream',
    read = true,
    write = true,
  }))
  got = runtime:perform(stream:reader():read_exactly_op(5))
  runtime:perform(stream:writer():write_op('pong'))
  flushed = runtime:perform(stream:writer():flush_op())
end, 'example-user')

assert(input_writer:write('hello') == 5)
runtime:drive({ host = host, max_iterations = 80 })
assert(got == 'hello' and flushed == true)
assert(output_reader:read(4) == 'pong')
print('examples/embedding/host_handle_stream.lua: ok')

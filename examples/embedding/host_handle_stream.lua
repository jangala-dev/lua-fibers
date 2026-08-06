package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

local External = require('fibers.embed.external')
local Handle = require('fibers.io.handle')
local SimulatedHost = require('examples.support.simulated_host')
local Scope = require('fibers.scope')
local fibers = require('fibers')
local Runtime = require('fibers.runtime')
local Stream = require('fibers.io.stream')

local host = SimulatedHost.new({ pipes = true, auto_advance_time = false })
local input, input_writer = assert(host:create_pipe({ label = 'example-input' }))
local output_reader, output = assert(host:create_pipe({ label = 'example-output' }))
local handle = Handle.new({
  host = host,
  label = 'example-duplex',
  key = { read = input:readiness_key(), write = output:readiness_key() },
  read = function(_, maximum) return input:read(maximum) end,
  write = function(_, bytes) return output:write(bytes) end,
  shutdown_read = function(_, reason) return input:shutdown_read(reason) end,
  shutdown_write = function(_, reason) return output:shutdown_write(reason) end,
  ready = function(_, mode)
    return mode == 'write' and output:write_ready_op() or input:read_ready_op()
  end,
  bind_runtime = function(_, rt)
    input:bind_runtime(rt)
    output:bind_runtime(rt)
  end,
  close = function(_, reason)
    local ok, err = input:close(reason)
    if not ok then return nil, err end
    return output:close(reason)
  end,
})
local runtime = Runtime.new({ host = host })
local scope = Scope.new({ runtime = runtime }):label('handle-example-scope')
local got, flushed

runtime:spawn_raw(function()
  local stream = runtime:perform(Stream.open_op(handle, {
    scope = scope,
    label = 'example-handle-stream',
    read = true,
    write = true,
  }))
  got = runtime:perform(stream:reader():read_exactly_op(5))
  runtime:perform(stream:writer():write_op('pong'))
  flushed = runtime:perform(stream:writer():flush_op())
end):label('example-user')

assert(input_writer:write('hello') == 5)
External.drive(runtime, { host = host, max_iterations = 80 })
assert(got == 'hello' and flushed == true)
assert(output_reader:read(4) == 'pong')
print('examples/embedding/host_handle_stream.lua: ok')

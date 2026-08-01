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
local fibers = require('fibers')
local Runtime = require('fibers.runtime')
local Scope = require('fibers.scope')
local Stream = require('fibers.io.stream')
local HostHandle = require('fibers.io.handle')
local SimulatedHost = require('examples.support.simulated_host')

-- This example is not a real socket implementation.  It shows the socket-shaped
-- contract: host readiness wakes the runtime reactor, and the handle read/write callbacks
-- remain authoritative.

local host = SimulatedHost.new({ auto_advance_time = false })

local socket = {
  key = 'example-socket',
  input = {},
  output = {},
}

function socket:feed(bytes)
  self.input[#self.input + 1] = bytes
  host:readable(self.key)
end

function socket:read(max)
  if #self.input == 0 then
    host:clear_readiness(self.key, 'read')
    return nil, 'would_block'
  end
  local first = self.input[1]
  local n = math.min(#first, max)
  local out = string.sub(first, 1, n)
  local rest = string.sub(first, n + 1)
  if rest == '' then
    table.remove(self.input, 1)
  else
    self.input[1] = rest
  end
  if #self.input == 0 then
    host:clear_readiness(self.key, 'read')
  end
  return out
end

function socket:write(bytes)
  self.output[#self.output + 1] = bytes
  return #bytes
end

function socket:written()
  return table.concat(self.output)
end

local handle = HostHandle.new({
  name = 'example-socket-handle',
  key = socket.key,
  host = host,
  read = function(_handle, max)
    return socket:read(max)
  end,
  write = function(_handle, bytes)
    return socket:write(bytes)
  end,
  close = function()
    return true
  end,
})

local rt = Runtime.new({ host = host })
local scope = Scope.new('example-socket-scope', { runtime = rt })
local stream, got, flushed

rt:spawn_raw(function()
  stream = rt:perform(
    Stream.open_op(handle, { scope = scope, read = true, write = true, name = 'example-socket-stream' })
  )
  got = rt:perform(stream:reader():read_exactly_op(4))
  rt:perform(stream:writer():write_op('pong'))
  flushed = rt:perform(stream:writer():flush_op())
end, 'root')

-- Opening the stream registers both directions with the shared reactor; the read then waits for host readiness.
External.drive(rt, { host = host, max_iterations = 20 })
assert(stream ~= nil)
assert(got == nil)

socket:feed('ping')
host:writable(socket.key)
External.drive(rt, { host = host, max_iterations = 120 })

assert(got == 'ping')
assert(flushed == true)
assert(socket:written() == 'pong')

print('examples/embedding/host_handle_socket.lua: ok')

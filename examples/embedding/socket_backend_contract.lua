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

-- This example is not a real socket implementation.  It shows the socket-shaped
-- contract: host readiness wakes the pump, and the backend read/write callbacks
-- remain authoritative.

local host = Host.manual({ auto_advance_time = false })

local handle = {
  key = 'example-socket',
  input = {},
  output = {},
}

function handle:feed(bytes)
  self.input[#self.input + 1] = bytes
  host:readable(self.key)
end

function handle:read(max)
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

function handle:write(bytes)
  self.output[#self.output + 1] = bytes
  return #bytes
end

function handle:written()
  return table.concat(self.output)
end

local backend = Stream.backend.Socket.new({
  name = 'example-socket-backend',
  key = handle.key,
  host = host,
  read = function(_backend, max)
    return handle:read(max)
  end,
  write = function(_backend, bytes)
    return handle:write(bytes)
  end,
})

local rt = Runtime.new({ host = host })
local region = Region.new('example-socket-region')
local stream, got, flushed

rt:spawn_raw(function()
  stream =
    rt:perform(Stream.open_backend_in_op(region, backend, { name = 'example-socket-stream' }))
  got = rt:perform(stream:reader():read_exactly_op(4))
  rt:perform(stream:writer():write_op('pong'))
  flushed = rt:perform(stream:writer():flush_op())
end, 'root')

-- Opening the stream starts the pumps; the read then waits for host readiness.
Runner.run(rt, { host = host, max_iterations = 20 })
assert(stream ~= nil)
assert(got == nil)

handle:feed('ping')
host:writable(handle.key)
Runner.run(rt, { host = host, max_iterations = 120 })

assert(got == 'ping')
assert(flushed == true)
assert(handle:written() == 'pong')

print('examples/embedding/socket_backend_contract.lua: ok')

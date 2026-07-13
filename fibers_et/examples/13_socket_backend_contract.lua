package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

local fibers = require('fibers')
local Stream = fibers.Stream

-- This example is not a real socket implementation.  It shows the socket-shaped
-- contract: host readiness wakes the pump, and the backend read/write callbacks
-- remain authoritative.

local host = fibers.host.manual({ auto_advance_time = false })

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

local rt = fibers.Runtime.new({ host = host })
local region = fibers.Region.new('example-socket-region')
local stream, got, flushed

rt:spawn_raw(function()
  stream =
    rt:perform(Stream.open_backend_in_op(region, backend, { name = 'example-socket-stream' }))
  got = rt:perform(stream:reader():read_exactly_op(4))
  rt:perform(stream:writer():write_op('pong'))
  flushed = rt:perform(stream:writer():flush_op())
end, 'root')

-- Opening the stream starts the pumps; the read then waits for host readiness.
fibers.Runner.run(rt, { host = host, max_iterations = 20 })
assert(stream ~= nil)
assert(got == nil)

handle:feed('ping')
host:writable(handle.key)
fibers.Runner.run(rt, { host = host, max_iterations = 120 })

assert(got == 'ping')
assert(flushed == true)
assert(handle:written() == 'pong')

print('examples/13_socket_backend_contract.lua: ok')

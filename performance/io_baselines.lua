-- Focused validating baselines for the external-resource substrate.
--
-- These are local regression measurements, not cross-machine claims.
-- Run from the repository root with:
--   lua performance/io_baselines.lua
--
-- Controls:
--   FIBERS_IO_BENCH_SCALE=2
--   FIBERS_IO_BENCH_REPEATS=5
--   FIBERS_IO_BENCH_CASE=datagram

local function join_path(prefix, suffix)
  if prefix == '' then
    return suffix
  end
  return prefix .. suffix
end

local argv0 = (arg and arg[0]) or ''
local here = argv0:match('^(.*[/\\])[^/\\]*$') or ''
local root = here:gsub('performance[/\\]$', '')

package.path = table.concat({
  join_path(root, 'src/?.lua'),
  join_path(root, 'src/?/init.lua'),
  join_path(root, 'src/?/?.lua'),
  join_path(root, '?.lua'),
  join_path(root, '?/init.lua'),
  join_path(root, '?/?.lua'),
  package.path,
}, ';')

local fibers = require('fibers')
local HostHold = require('fibers.io.internal.host_hold')
local File = require('fibers.file')
local SimulatedHost = require('tests.support.simulated_host')
local Runtime = require('fibers.runtime')
local Socket = require('fibers.socket')
local Stream = require('fibers.stream')
local Clock = require('performance.clock')

local function env_number(name, default)
  local value = tonumber(os.getenv(name) or '')
  if not value or value <= 0 then
    return default
  end
  return value
end

local scale = env_number('FIBERS_IO_BENCH_SCALE', 1)
local repeats = math.max(1, math.floor(env_number('FIBERS_IO_BENCH_REPEATS', 1)))
local filter = os.getenv('FIBERS_IO_BENCH_CASE') or ''

local function median(values)
  table.sort(values)
  local n = #values
  if n % 2 == 1 then
    return values[(n + 1) / 2]
  end
  return (values[n / 2] + values[n / 2 + 1]) / 2
end

local cases = {}
local function add(name, units, fn)
  cases[#cases + 1] = { name = name, units = units, fn = fn }
end

add('host-hold', 'resources', function()
  local count = math.max(1, math.floor(1000 * scale))
  for i = 1, count do
    local slot = HostHold.new('bench-host-hold-' .. tostring(i))
    local value = { id = i }
    assert(slot:hold('value', value, function()
      return true
    end))
    assert(slot:release('value', value) == value)
    assert(slot:close('benchmark'))
  end
  return count
end)

add('memory-stream-throughput', 'bytes', function()
  local chunks = math.max(1, math.floor(64 * scale))
  local chunk = string.rep('x', 4096)
  local expected = chunks * #chunk
  local received

  fibers.run(function(scope)
    local writer, reader = Stream.memory_pair({
      label = 'io-baseline-memory',
      capacity = 65536,
    })
    local producer = scope:spawn(function()
      for _ = 1, chunks do
        writer:write(chunk)
      end
      writer:shutdown_write('benchmark complete')
    end):label('io-baseline-writer')

    local parts = {}
    local total = 0
    while total < expected do
      local bytes = assert(reader:read_some(math.min(16384, expected - total)))
      parts[#parts + 1] = bytes
      total = total + #bytes
    end
    received = table.concat(parts)
    producer:await()
    writer:close('benchmark complete')
    reader:close('benchmark complete')
  end)

  assert(#received == expected)
  return expected
end)

add('socket-accept', 'connections', function()
  local count = math.max(1, math.floor(8 * scale))
  local host = SimulatedHost.new({ sockets = true, pipes = true })
  local accepted = 0

  fibers.run(function(scope)
    local listener = assert(Socket.listen_ipv4('127.0.0.1', 0, {
      accept_capacity = count,
    }))
    local address = listener:local_address()
    local server = scope:spawn(function()
      for _ = 1, count do
        local connection = assert(listener:accept())
        accepted = accepted + 1
        connection:close('benchmark accepted')
      end
    end):label('io-baseline-acceptor')

    for _ = 1, count do
      local dial = Socket.dial(address)
      local connection = assert(dial:result())
      connection:close('benchmark dialled')
    end

    server:await()
    listener:close('benchmark complete')
  end, { host = host })

  assert(accepted == count)
  return count
end)

add('datagram-roundtrip', 'datagrams', function()
  local count = math.max(1, math.floor(64 * scale))
  local host = SimulatedHost.new({ datagrams = true })
  local received = 0

  fibers.run(function()
    local sender = assert(Socket.udp_ipv4('127.0.0.1', 0, {
      send_capacity = count,
    }))
    local receiver = assert(Socket.udp_ipv4('127.0.0.1', 0, {
      receive_capacity = count,
    }))

    for i = 1, count do
      sender:send_to(tostring(i), receiver:local_address())
    end
    sender:flush()

    for i = 1, count do
      local packet = assert(receiver:receive_from())
      assert(packet.data == tostring(i))
      received = received + 1
    end

    sender:close('benchmark complete')
    receiver:close('benchmark complete')
  end, { host = host })

  assert(received == count)
  return count
end)

add('idle-reactor-registration', 'registrations', function()
  local count = math.max(1, math.floor(16 * scale))
  local host = SimulatedHost.new({ pipes = true })
  local registrations

  fibers.run(function()
    local endpoints = {}
    for i = 1, count do
      local reader, writer = assert(File.pipe({ label = 'io-baseline-pipe-' .. tostring(i) }))
      endpoints[#endpoints + 1] = reader
      endpoints[#endpoints + 1] = writer
    end

    local runtime = Runtime.current()
    registrations = runtime.host_reactor and runtime.host_reactor:registration_count() or 0
    assert(registrations == count * 2)

    for i = 1, #endpoints do
      endpoints[i]:close('benchmark complete')
    end
  end, { host = host })

  return registrations
end)

print('Fibers I/O baselines (' .. Clock.name .. ')')
for _, case in ipairs(cases) do
  if filter == '' or case.name:find(filter, 1, true) then
    local elapsed = {}
    local units
    for _ = 1, repeats do
      collectgarbage('collect')
      local started = Clock.now()
      units = case.fn()
      local finished = Clock.now()
      elapsed[#elapsed + 1] = math.max(finished - started, 1e-9)
    end
    local seconds = median(elapsed)
    print(
      string.format(
        '%-28s %12.0f %-13s %10.3f ms %12.0f/s',
        case.name,
        units,
        case.units,
        seconds * 1000,
        units / seconds
      )
    )
  end
end

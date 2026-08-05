package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

local fibers = require('fibers')
local socket = require('fibers.socket')
local SimulatedHost = require('tests.support.simulated_host')

local function assert_truthy(value, message)
  if not value then
    error(message or 'expected truthy value', 2)
  end
end

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error(
      (message or 'values differ') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual),
      2
    )
  end
end

local function echo_once(host, address)
  local server_result
  local client_result
  local report = fibers.try_run(function(scope)
    local listener, listen_err = socket.listen(address, {
      accept_capacity = 4,
      read_capacity = 128,
      write_capacity = 128,
    })
    assert_truthy(listener, 'listen failed: ' .. tostring(listen_err))
    local actual = listener:local_address()

    local server = scope:spawn(function()
      local connection, accept_err = listener:accept()
      assert_truthy(connection, 'accept failed: ' .. tostring(accept_err))
      local line, read_err = connection:read('*l')
      assert_truthy(line, 'server read failed: ' .. tostring(read_err))
      connection:write('echo:' .. line .. '\n')
      connection:flush()
      connection:close('server complete')
      server_result = line
    end):label('socket-conformance-server')

    local dial = socket.dial(actual)
    local connection, dial_err = dial:result()
    assert_truthy(connection, 'dial failed: ' .. tostring(dial_err))
    connection:write('hello\n')
    connection:flush()
    client_result = connection:read('*l')
    connection:close('client complete')
    server:await()
    listener:close('test complete')
  end, { host = host })

  assert_truthy(report.ok, 'socket conformance run failed: ' .. tostring(report.primary))
  assert_eq(server_result, 'hello', 'server should receive client line')
  assert_eq(client_result, 'echo:hello', 'client should receive echo line')
end

local host = SimulatedHost.new({ sockets = true, pipes = true })
echo_once(host, socket.ipv4_address('127.0.0.1', 0))
echo_once(host, socket.ipv6_address('::1', 0))
echo_once(host, socket.unix_address('/manual/socket-conformance'))

-- A small reuse check remains in the ordinary semantic suite. Sustained
-- registration and connection churn lives in tests/stress/test_socket_churn.lua.
local reuse = fibers.try_run(function(scope)
  local listener = assert(socket.listen_inet('127.0.0.1', 0, { accept_capacity = 2 }))
  local address = listener:local_address()
  local count = 2
  local server = scope:spawn(function()
    for i = 1, count do
      local connection = assert(listener:accept())
      local byte = assert(connection:read(1))
      connection:write(byte)
      connection:flush()
      connection:close('reuse server complete')
    end
  end):label('socket-reuse-server')

  for i = 1, count do
    local dial = socket.dial(address)
    local connection = assert(dial:result())
    local byte = string.char(64 + i)
    connection:write(byte)
    connection:flush()
    assert_eq(connection:read(1), byte, 'client reuse byte')
    connection:close('reuse client complete')
  end

  server:await()
  listener:close('reuse complete')
end, { host = SimulatedHost.new({ sockets = true, pipes = true }) })
assert_truthy(reuse.ok, 'socket reuse failed: ' .. tostring(reuse.error))

print('tests/io/test_socket_conformance.lua: ok')

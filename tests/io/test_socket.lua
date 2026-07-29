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
local Op = require('fibers.op')
local Host = require('fibers.host')
local SimulatedHost = require('tests.support.simulated_host')
local HostError = require('fibers.host.error')
local socket = require('fibers.socket')

local function assert_eq(a, b, msg)
  if a ~= b then
    error((msg or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2)
  end
end

local function assert_truthy(v, msg)
  if not v then
    error(msg or 'expected truthy', 2)
  end
end

-- Listening, dialling and accepting preserve the original Stream-shaped surface.
do
  local host = SimulatedHost.new({ sockets = true, auto_advance_time = false })
  fibers.run(function()
    local listener, listen_err =
      fibers.perform(socket.listen_inet_op('127.0.0.1', 0, { name = 'echo-listener' }))
    assert_truthy(listener, tostring(listen_err))
    local local_address = listener:local_address()
    assert_truthy(local_address.port ~= 0)

    local client_task = fibers.spawn(function()
      local dial = fibers.perform(
        socket.dial_op(socket.inet_address(local_address.host, local_address.port), { name = 'echo-client' })
      )
      local client, dial_err = fibers.perform(dial:result_op())
      assert_truthy(client, tostring(dial_err))
      local report = fibers.perform(dial:report_op())
      assert_eq(report.kind, 'dial')
      assert_eq(report.strategy, 'direct')
      assert_eq(report.status, 'connected')
      assert_eq(fibers.perform(client:write_op('ping\n')), 5)
      local response, read_err = fibers.perform(client:read_line_op())
      assert_eq(response, 'pong', tostring(read_err))
      assert_eq(fibers.perform(client:close_op('client complete')), true)
    end, 'socket-client')

    local server, accept_err = fibers.perform(listener:accept_op())
    assert_truthy(server, tostring(accept_err))
    local request, read_err = fibers.perform(server:read_line_op())
    assert_eq(request, 'ping', tostring(read_err))
    assert_eq(fibers.perform(server:write_op('pong\n')), 5)
    assert_eq(fibers.perform(server:flush_op()), true)
    assert_eq(fibers.perform(server:close_op('server complete')), true)
    fibers.perform(client_task:await_op())
    assert_eq(fibers.perform(listener:close_op('test complete')), true)
    assert_eq(fibers.perform(listener:closed_op()), true)
  end, { host = host })
end

-- A failed dial remains a Dial result; the start option itself still commits.
do
  local host = SimulatedHost.new({ sockets = true, auto_advance_time = false })
  fibers.run(function()
    local dial = fibers.perform(socket.dial_op(socket.inet_address('127.0.0.1', 6553)))
    local connection, err = fibers.perform(dial:result_op())
    assert_eq(connection, nil)
    assert_truthy(HostError.is(err, 'system'))
    assert_eq(err.code, 'ECONNREFUSED')
  end, { host = host })
end

-- Losing listener admission performs no host acquisition.
do
  local host = SimulatedHost.new({ sockets = true, auto_advance_time = false })
  local before = 0
  for _ in pairs(host.socket_listeners) do
    before = before + 1
  end
  fibers.run(function()
    local result = fibers.perform(Op.always('winner'):or_else(socket.listen_inet_op('127.0.0.1', 8123)))
    assert_eq(result, 'winner')
  end, { host = host })
  local after = 0
  for _ in pairs(host.socket_listeners) do
    after = after + 1
  end
  assert_eq(after, before)
end

-- Unsupported hosts report structured expected errors.
do
  local listener, err
  fibers.run(function()
    listener, err = fibers.perform(socket.listen_inet_op('127.0.0.1', 0))
  end, {
    host = Host.pure({
      now = function()
        return 0
      end,
      sleep = function()
        return true
      end,
    }),
  })
  assert_eq(listener, nil)
  assert_truthy(HostError.is_unsupported(err, 'listen'))
end

print('tests/io/test_socket.lua: ok')

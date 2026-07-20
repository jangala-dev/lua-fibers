local fibers = require('fibers')
local socket = require('fibers.socket')
local HostError = require('fibers.host.error')

local Contract = {}

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error(
      (message or 'values differ') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual),
      3
    )
  end
end

local function assert_truthy(value, message)
  if not value then
    error(message or 'expected truthy value', 3)
  end
end

local function close_host(host)
  if host and type(host.close) == 'function' then
    host:close()
  end
end

function Contract.exercise(name, host, address, opts)
  opts = opts or {}
  local accepted_local, accepted_peer, client_local, client_peer
  local result = fibers.try_run(function(scope)
    local listener, listen_err = socket.listen(address, {
      name = name .. ':listener',
      accept_capacity = 2,
      unlink_existing = true,
      unlink_on_close = true,
    })
    assert_truthy(listener, name .. ' listen failed: ' .. tostring(listen_err))
    local bound = listener:local_address()

    local server = scope:spawn(function()
      local connection, accept_err = listener:accept()
      assert_truthy(connection, name .. ' accept failed: ' .. tostring(accept_err))
      accepted_local = connection:local_address()
      accepted_peer = connection:peer_address()
      local byte, read_err = connection:read(1)
      assert_eq(byte, 'x', name .. ' accepted read: ' .. tostring(read_err))
      assert_eq(connection:write('y'), 1, name .. ' accepted write')
      assert_eq(connection:flush(), true, name .. ' accepted flush')
      assert_eq(connection:close('server complete'), true, name .. ' accepted close')
    end, name .. ':server')

    local dial = socket.dial(bound, { name = name .. ':dial' })
    local connection, dial_err = dial:result()
    assert_truthy(connection, name .. ' dial failed: ' .. tostring(dial_err))
    client_local = connection:local_address()
    client_peer = connection:peer_address()
    assert_eq(connection:write('x'), 1, name .. ' client write')
    assert_eq(connection:flush(), true, name .. ' client flush')
    local byte, read_err = connection:read(1)
    assert_eq(byte, 'y', name .. ' client read: ' .. tostring(read_err))
    assert_eq(connection:close('client complete'), true, name .. ' client close')
    server:await()
    assert_eq(listener:close('contract complete'), true, name .. ' listener close')
    assert_eq(listener:closed(), true, name .. ' listener closed')
  end, { host = host, max_iterations = opts.max_iterations or 20000 })

  assert_truthy(result.ok, name .. ' provider contract failed: ' .. tostring(result.primary or result))
  result.runtime:assert_io_quiescent(name .. ' provider contract')
  assert_truthy(accepted_local, name .. ' accepted connection should expose local address')
  assert_truthy(accepted_peer, name .. ' accepted connection should expose peer address')
  assert_truthy(client_peer, name .. ' client connection should expose peer address')
  if opts.require_client_local then
    assert_truthy(client_local, name .. ' client connection should expose local address')
  end
  return true
end

function Contract.expect_unsupported(name, host, address)
  local result = fibers.try_run(function()
    local listener, err = socket.listen(address)
    assert_eq(listener, nil, name .. ' unsupported listener')
    assert_truthy(HostError.is_unsupported(err, 'listen'), name .. ' should return unsupported listen')
  end, { host = host })
  assert_truthy(result.ok, name .. ' unsupported contract failed: ' .. tostring(result.primary or result))
  return true
end

function Contract.close_host(host)
  close_host(host)
end

return Contract

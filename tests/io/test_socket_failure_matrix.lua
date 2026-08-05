package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

local IOAudit = require('fibers.diagnostics.io')
local fibers = require('fibers')
local Op = require('fibers.op')
local Sleep = require('fibers.sleep')
local socket = require('fibers.socket')
local SimulatedHost = require('tests.support.simulated_host')
local HostError = require('fibers.io.error')
local Handle = require('fibers.io.handle')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error(
      (message or 'values differ') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual),
      2
    )
  end
end

local function assert_truthy(value, message)
  if not value then
    error(message or 'expected truthy value', 2)
  end
end

local function pending_dial_host()
  local pending
  local host
  host = SimulatedHost.new({
    sockets = true,
    dial_factory = function(self, address, opts)
      -- Keep the real connected pipe pair behind a separate readiness gate. The
      -- gate models an EINPROGRESS socket without inheriting the pipe writer's
      -- permanently writable level, so the completion timer can run normally.
      local connected, peer, err = self:_manual_dial_socket(address, opts)
      if not connected then
        return nil, err
      end

      local handle
      handle = Handle.new({
        name = (opts and opts.name or 'pending-dial') .. ':gate',
        host = self,
        capabilities = {
          read = true,
          write = true,
          shutdown_read = true,
          shutdown_write = true,
          close = true,
          readiness = true,
        },
        read = function(_self, max)
          return connected:read(max)
        end,
        write = function(_self, bytes)
          return connected:write(bytes)
        end,
        shutdown_read = function(_self, reason)
          return connected:shutdown_read(reason)
        end,
        shutdown_write = function(_self, reason)
          return connected:shutdown_write(reason)
        end,
        close = function(_self, reason)
          return connected:close(reason)
        end,
      })
      handle._connect_pending = true
      handle._connect_complete = false
      handle._allow_finish = false
      function handle:finish_connect()
        if self.closed then
          return nil, nil, HostError.closed('socket', 'connect_finish')
        end
        if not self._allow_finish then
          return nil, nil, HostError.would_block('socket', 'connect_finish')
        end
        self._connect_pending = false
        self._connect_complete = true
        return self, peer
      end
      function handle:local_address()
        if type(connected.local_address) == 'function' then
          return connected:local_address()
        end
        return connected.local_address_value
      end
      function handle:peer_address_value()
        if type(connected.peer_address_value) == 'function' then
          return connected:peer_address_value()
        end
        return peer
      end
      pending = handle
      return handle
    end,
  })
  return host, function()
    return pending
  end
end

-- An external timeout is not a connection failure. The pending Dial remains an
-- resource held in custody and closes cleanly when the caller abandons it.
do
  local host, get_pending = pending_dial_host()
  local result = fibers.try_run(function()
    local listener = socket.listen_ipv4('127.0.0.1', 0, { name = 'pending-timeout-listener' })
    local dial = socket.dial(listener:local_address(), { name = 'pending-timeout-dial' })
    local value, err = fibers.perform(Op.choice(
      dial:result_op(fibers.current_scope()),
      Sleep.sleep_op(0.01):map(function()
        return nil, { kind = 'timeout' }
      end)
    ))
    assert_eq(value, nil)
    assert_eq(err.kind, 'timeout')
    assert_eq(dial:close('timeout won'), true)
    assert_eq(dial:closed(), true)
    local later, later_err = dial:result()
    assert_eq(later, nil)
    assert_truthy(HostError.is(later_err, 'closed'))
    listener:close('timeout test complete')
    listener:closed()
  end, { host = host })
  assert_truthy(result.ok, result:tostring())
  assert_truthy(get_pending().closed, 'pending host handle should close after Dial abandonment')
  IOAudit.assert_clean(result.runtime, { label = 'pending dial timeout' })
end

-- A delayed authoritative connect completion wins when readiness arrives before
-- the caller's timeout.
do
  local host, get_pending = pending_dial_host()
  local result = fibers.try_run(function(scope)
    local listener = socket.listen_ipv4('127.0.0.1', 0, { name = 'delayed-success-listener' })
    local server = scope:spawn(function()
      local connection = assert(listener:accept())
      connection:close('server accepted delayed connection')
    end):label('delayed-success-server')
    local dial = socket.dial(listener:local_address(), { name = 'delayed-success-dial' })
    scope:spawn(function()
      Sleep.sleep(0.01)
      local handle = assert(get_pending(), 'pending handle should exist')
      handle._allow_finish = true
      handle:mark_writable()
    end):label('delayed-connect-completion')
    local connection, err = fibers.perform(Op.choice(
      dial:result_op(fibers.current_scope()),
      Sleep.sleep_op(1):map(function()
        return nil, { kind = 'timeout' }
      end)
    ))
    assert_truthy(connection, tostring(err))
    assert_truthy(connection:local_address())
    assert_truthy(connection:peer_address())
    connection:close('delayed client complete')
    server:await()
    listener:close('delayed success complete')
    listener:closed()
  end, { host = host })
  assert_truthy(result.ok, result:tostring())
  IOAudit.assert_clean(result.runtime, { label = 'delayed dial success' })
end

-- A pending accept is released by listener closure with a structured terminal
-- result rather than waiting indefinitely.
do
  local host = SimulatedHost.new({ sockets = true })
  local result = fibers.try_run(function(scope)
    local listener = socket.listen_ipv4('127.0.0.1', 0, { name = 'blocked-accept-listener' })
    local accepted, accept_err
    local waiter = scope:spawn(function()
      accepted, accept_err = listener:accept()
    end):label('blocked-accept')
    Sleep.sleep(0)
    listener:close('close blocked accept')
    waiter:await()
    assert_eq(accepted, nil)
    assert_truthy(HostError.is(accept_err, 'closed'))
    listener:closed()
  end, { host = host })
  assert_truthy(result.ok, result:tostring())
  IOAudit.assert_clean(result.runtime, { label = 'blocked accept closure' })
end

-- Binding an occupied address is a normal expected host failure.
do
  local host = SimulatedHost.new({ sockets = true })
  local result = fibers.try_run(function()
    local first = socket.listen_ipv4('127.0.0.1', 8127, { name = 'address-owner' })
    local second, err = socket.listen_ipv4('127.0.0.1', 8127, { name = 'address-conflict' })
    assert_eq(second, nil)
    assert_truthy(HostError.is(err, 'system'))
    assert_eq(err.code, 'EADDRINUSE')
    first:close('address conflict complete')
    first:closed()
  end, { host = host })
  assert_truthy(result.ok, result:tostring())
  IOAudit.assert_clean(result.runtime, { label = 'address conflict' })
end

-- Stream half-close preserves queued output and produces EOF; closing the peer's
-- read direction makes later writes fail as a broken pipe.
do
  local host = SimulatedHost.new({ sockets = true })
  local result = fibers.try_run(function(scope)
    local listener = socket.listen_ipv4('127.0.0.1', 0, { name = 'half-close-listener' })
    local server = scope:spawn(function()
      local connection = assert(listener:accept())
      connection:write('tail')
      connection:flush()
      connection:shutdown_read('server accepts no client data')
      connection:shutdown_write('server output complete')
      connection:closed()
    end):label('half-close-server')
    local client = assert(socket.dial(listener:local_address()):result())
    local bytes, read_err = client:read_all({ max = 16 })
    assert_eq(bytes, 'tail', tostring(read_err))
    assert_eq(client:write('x'), 1)
    local flushed, write_err = client:flush()
    assert_eq(flushed, nil)
    assert_truthy(type(write_err) == 'table' and write_err.kind == 'broken_pipe')
    client:abort('half-close client complete')
    server:await()
    listener:close('half-close complete')
    listener:closed()
  end, { host = host })
  assert_truthy(result.ok, result:tostring())
  IOAudit.assert_clean(result.runtime, { label = 'half-close' })
end

print('tests/io/test_socket_failure_matrix.lua: ok')

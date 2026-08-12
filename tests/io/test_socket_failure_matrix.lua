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
local Connection = require('fibers.socket.connection')
local Runtime = require('fibers.runtime')
local Protected = require('fibers.protected')

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
        label = (opts and opts.label or 'pending-dial') .. ':gate',
        host = self,
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
    local listener = socket.listen_ipv4('127.0.0.1', 0, { label = 'pending-timeout-listener' })
    local dial = socket.dial(listener:local_address(), { label = 'pending-timeout-dial' })
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
  assert_truthy(get_pending()._closed, 'pending host handle should close after Dial abandonment')
  IOAudit.assert_clean(result.runtime, { label = 'pending dial timeout' })
end

-- A delayed authoritative connect completion wins when readiness arrives before
-- the caller's timeout.
do
  local host, get_pending = pending_dial_host()
  local result = fibers.try_run(function(scope)
    local listener = socket.listen_ipv4('127.0.0.1', 0, { label = 'delayed-success-listener' })
    local server = scope:spawn(function()
      local connection = assert(listener:accept())
      connection:close('server accepted delayed connection')
    end):label('delayed-success-server')
    local dial = socket.dial(listener:local_address(), { label = 'delayed-success-dial' })
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
    local listener = socket.listen_ipv4('127.0.0.1', 0, { label = 'blocked-accept-listener' })
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
    local first = socket.listen_ipv4('127.0.0.1', 8127, { label = 'address-owner' })
    local second, err = socket.listen_ipv4('127.0.0.1', 8127, { label = 'address-conflict' })
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
    local listener = socket.listen_ipv4('127.0.0.1', 0, { label = 'half-close-listener' })
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


-- A host address accessor is part of the adapter contract. If it raises during
-- Listener activation, the held handle is discarded and the lifecycle is made
-- terminal before the structured protocol error escapes.
do
  local closed = 0
  local host = SimulatedHost.new({ sockets = true })
  local create_listener = host.create_listener
  host.create_listener = function(self, address, opts)
    local handle, err = create_listener(self, address, opts)
    if not handle then return nil, err end
    local close = handle._close
    handle._close = function(self_handle, reason)
      closed = closed + 1
      return close(self_handle, reason)
    end
    handle.local_address = function()
      error('injected local_address defect')
    end
    return handle
  end

  local result = fibers.try_run(function()
    local ok, err = Protected.pcall(function()
      return socket.listen_ipv4('127.0.0.1', 0, { label = 'bad-local-address-listener' })
    end)
    assert_eq(ok, false)
    assert_truthy(HostError.is(err, 'protocol'), 'address accessor defect should be a protocol error')
    assert_truthy(tostring(err):match('injected local_address defect'))
  end, { host = host })

  assert_eq(result.ok, false, 'fatal address accessor defect should remain visible to Scope Closure')
  assert_truthy(tostring(result):match('injected local_address defect'))
  assert_eq(closed, 1, 'failed activation must close its held handle exactly once')
  IOAudit.assert_clean(result.runtime, { label = 'listener address accessor failure' })
end

-- Address discovery happens before Stream admission. An accessor defect closes
-- the still-unadmitted host handle and returns a structured error.
do
  local result = fibers.try_run(function(scope)
    local closed = 0
    local handle = Handle.new({
      label = 'bad-connected-address-handle',
      read = function() return nil, HostError.would_block('socket', 'read') end,
      write = function(_self, bytes) return #bytes end,
      close = function()
        closed = closed + 1
        return true
      end,
    })
    function handle:local_address()
      error('injected connected local_address defect')
    end
    function handle:peer_address()
      return socket.ipv4_address('192.0.2.2', 80)
    end

    local connection, err = Connection.open_from_host(
      Runtime.current(),
      scope,
      handle,
      { action = 'open_connection', address = socket.ipv4_address('192.0.2.1', 80) }
    )
    assert_eq(connection, nil)
    assert_truthy(HostError.is(err, 'protocol'))
    assert_truthy(tostring(err):match('injected connected local_address defect'))
    assert_eq(closed, 1, 'failed address discovery must close the unadmitted handle')
  end, { host = SimulatedHost.new() })

  assert_truthy(result.ok, result:tostring())
  IOAudit.assert_clean(result.runtime, { label = 'connected address accessor failure' })
end

-- If address discovery and disposal both fail, the returned setup error retains
-- both failures without admitting a structurally broken Stream.
do
  local returned_err
  local result = fibers.try_run(function(scope)
    local handle = Handle.new({
      label = 'bad-connected-address-cleanup-handle',
      read = function() return nil, HostError.would_block('socket', 'read') end,
      write = function(_self, bytes) return #bytes end,
      close = function()
        return nil, HostError.system('socket', 'close', 'injected Stream close failure', 'EIO')
      end,
    })
    function handle:local_address() error('injected connected address defect') end
    function handle:peer_address() return socket.ipv4_address('192.0.2.2', 80) end

    local connection
    connection, returned_err = Connection.open_from_host(
      Runtime.current(), scope, handle,
      { action = 'open_connection', address = socket.ipv4_address('192.0.2.1', 80) }
    )
    assert_eq(connection, nil)
    assert_truthy(HostError.is(returned_err, 'protocol'))
    assert_truthy(returned_err.errors and #returned_err.errors == 2,
      'setup error should retain address and Stream-abort failures')
  end, { host = SimulatedHost.new() })

  assert_eq(result.ok, true, 'failed pre-admission handle close must not create a Scope Closure failure')
  assert_truthy(returned_err and tostring(returned_err):match('handle disposal both failed'))
end


-- If a failed direct connection attempt also fails to close its acquired handle,
-- the cleanup defect must be retained in the Dial result rather than discarded.
do
  local close_calls = 0
  local host = SimulatedHost.new({
    sockets = true,
    dial_factory = function(self)
      local handle = Handle.new({
        label = 'failing-connect-cleanup-handle',
        host = self,
        close = function()
          close_calls = close_calls + 1
          return nil, HostError.system('socket', 'close', 'injected dial close failure', 'EIO')
        end,
      })
      function handle:finish_connect()
        return nil, nil, HostError.system(
          'socket', 'connect_finish', 'injected connect failure', 'ECONNREFUSED'
        )
      end
      handle:mark_writable()
      return handle
    end,
  })

  fibers.run(function()
    local dial = socket.dial(socket.ipv4_address('127.0.0.1', 9), {
      label = 'failing-connect-cleanup-dial',
    })
    local connection, err = dial:result()
    assert_eq(connection, nil)
    assert_truthy(HostError.is(err, 'protocol'), 'connect plus cleanup failure should aggregate')
    assert_truthy(tostring(err):match('cleanup was incomplete'))
    assert_truthy(err.errors and #err.errors >= 2, 'aggregate should retain primary and cleanup errors')
    assert_eq(close_calls, 1)
  end, { host = host })
end


-- finish_connect completes the already-held handle. Returning a replacement
-- handle would break continuous handle coverage, so the adapter contract rejects
-- it and closes both the replacement and original handles.
do
  local original_closes, replacement_closes = 0, 0
  local host = SimulatedHost.new({
    sockets = true,
    dial_factory = function(self)
      local replacement = Handle.new({
        label = 'replacement-connected-handle',
        host = self,
        close = function()
          replacement_closes = replacement_closes + 1
          return true
        end,
      })
      local original = Handle.new({
        label = 'original-pending-handle',
        host = self,
        close = function()
          original_closes = original_closes + 1
          return true
        end,
      })
      function original:finish_connect()
        return replacement, socket.ipv4_address('127.0.0.1', 9)
      end
      original:mark_writable()
      return original
    end,
  })

  local result = fibers.try_run(function()
    local dial = socket.dial(socket.ipv4_address('127.0.0.1', 9), {
      label = 'replacement-handle-dial',
    })
    local connection, err = dial:result()
    assert_eq(connection, nil)
    assert_truthy(HostError.is(err, 'protocol'))
    assert_truthy(tostring(err):match('original host handle'))
  end, { host = host })

  assert_truthy(result.ok, result:tostring())
  assert_eq(replacement_closes, 1, 'replacement handle must be closed immediately')
  assert_eq(original_closes, 1, 'original held handle must close with failed attempt')
  IOAudit.assert_clean(result.runtime, { label = 'finish_connect replacement handle' })
end

print('tests/io/test_socket_failure_matrix.lua: ok')

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
local Sleep = require('fibers.sleep')
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

local function yield_turns(n)
  for _ = 1, (n or 1) do
    Sleep.sleep(0)
  end
end

local function wait_for_queue(listener, count)
  while true do
    local rows = fibers.perform(listener.queue:snapshot_op())
    if #rows >= count then
      return rows
    end
    yield_turns(1)
  end
end

-- Acceptance transfers the complete Stream subtree into the accepting scope.
do
  local host = SimulatedHost.new({ sockets = true })
  local accepted
  fibers.run(function(root)
    local listener = socket.listen_inet('127.0.0.1', 0, { name = 'ownership-listener' })
    local address = listener:local_address()
    local dial = socket.dial_inet(address.host, address.port, { name = 'ownership-client' })
    local client = dial:result()

    fibers.scope({ name = 'connection-handler' }, function(handler)
      accepted = listener:accept()
      assert_eq(accepted.owner, handler:raw_region(), 'accepted Stream should move into handler scope')
      assert_truthy(
        accepted:reader().owner == handler:raw_region(),
        'reader child should move with Stream subtree'
      )
      assert_truthy(
        accepted:writer().owner == handler:raw_region(),
        'writer child should move with Stream subtree'
      )
    end)

    assert_eq(accepted.owner, nil, 'handler settlement should release the accepted Stream')
    assert_truthy(accepted.handle.closed, 'handler settlement should close the accepted host handle')
    client:close('ownership test complete')
    listener:close('ownership test complete')
    listener:closed()
  end, { host = host })
end

-- An explicitly supplied scope-owned Region remains a supported custody
-- target; the associated Scope supplies the driver's structured execution
-- context.
do
  local host = SimulatedHost.new({ sockets = true })
  fibers.run(function(root)
    local owner = root:raw_region()
    local listener = socket.listen_inet('127.0.0.1', 0, {
      name = 'region-owned-listener',
      owner = owner,
    })
    local address = listener:local_address()
    local dial = socket.dial_inet(address.host, address.port, {
      name = 'region-owned-dial',
      owner = owner,
    })
    local client = dial:result(root)
    local server = listener:accept(root)
    client:close('region owner test complete')
    server:close('region owner test complete')
    listener:close('region owner test complete')
    listener:closed()
  end, { host = host })
end

-- Listener and Dial driver tasks are structural children, so moving the
-- resource root carries its driver obligation with it.
do
  local host = SimulatedHost.new({ sockets = true })
  fibers.run(function(root)
    local listener
    fibers.scope({ name = 'listener-origin' }, function(origin)
      listener = socket.listen_inet('127.0.0.1', 0, { name = 'moved-listener' })
      assert_eq(listener.driver.owner, origin:raw_region())
      fibers.perform(origin:move_op(listener, root))
      assert_eq(listener.owner, root:raw_region())
      assert_eq(listener.driver.owner, root:raw_region(), 'Listener move should carry driver child')
    end)

    local address = listener:local_address()
    local dial
    fibers.scope({ name = 'dial-origin' }, function(origin)
      dial = socket.dial_inet(address.host, address.port, { name = 'moved-dial' })
      assert_eq(dial.driver.owner, origin:raw_region())
      fibers.perform(origin:move_op(dial, root))
      assert_eq(dial.owner, root:raw_region())
      assert_eq(dial.driver.owner, root:raw_region(), 'Dial move should carry driver child')
    end)

    local client = dial:result()
    local server = listener:accept()
    client:close('moved resource test complete')
    server:close('moved resource test complete')
    listener:close('moved resource test complete')
    listener:closed()
  end, { host = host })
end

-- A full accepted-connection queue must not make Listener closure uninterruptible.
do
  local host = SimulatedHost.new({ sockets = true })
  fibers.run(function()
    local listener = socket.listen_inet('127.0.0.1', 0, {
      name = 'full-queue-listener',
      accept_capacity = 1,
    })
    local address = listener:local_address()
    local c1 = socket.dial_inet(address.host, address.port, { name = 'full-queue-client-1' }):result()
    local c2 = socket.dial_inet(address.host, address.port, { name = 'full-queue-client-2' }):result()

    local rows = wait_for_queue(listener, 1)
    yield_turns(2) -- allow the driver to reach the second, blocked queue insertion
    assert_eq(#rows, 1)

    assert_eq(listener:close('queue-full shutdown'), true)
    assert_eq(listener:closed(), true)
    assert_truthy(rows[1].value.handle.closed, 'queued connection should close with driver scope')

    c1:close('queue-full test complete')
    c2:close('queue-full test complete')
  end, { host = host })
end

-- A queued connection remains preferred when closure commits at the same time.
do
  local host = SimulatedHost.new({ sockets = true })
  fibers.run(function()
    local listener = socket.listen_inet('127.0.0.1', 0, { name = 'close-race-listener' })
    local address = listener:local_address()
    local client = socket.dial_inet(address.host, address.port, { name = 'close-race-client' }):result()
    wait_for_queue(listener, 1)

    fibers.perform(listener.lifecycle:request_stop_op('simulated terminal listener'))
    local accepted = listener:accept()
    assert_truthy(accepted, 'queued accept should beat terminal listener fallback')
    assert_eq(accepted.owner, fibers.current_scope():raw_region())

    accepted:close('accepted during close')
    listener:host_handle():close('simultaneous close')
    listener.driver:request_cancel('simultaneous close')
    listener:closed()
    client:close('close-race test complete')
  end, { host = host })
end

-- An unclaimed successful Dial remains in its driver scope and is closed by
-- Dial settlement; it never leaks into the surrounding scope.
do
  local host = SimulatedHost.new({ sockets = true })
  local dial_ref, connection_ref
  fibers.run(function()
    local listener = socket.listen_inet('127.0.0.1', 0, { name = 'unclaimed-listener' })
    local address = listener:local_address()

    fibers.scope({ name = 'unclaimed-dial-scope' }, function()
      dial_ref = socket.dial_inet(address.host, address.port, { name = 'unclaimed-dial' })
      local connected_state = fibers.perform(dial_ref.lifecycle:connected_state_op())
      connection_ref = connected_state.connection
      assert_truthy(connection_ref, 'dial should have a successful unclaimed connection')
      assert_eq(connection_ref.owner, connected_state.source_region)
      assert_eq(fibers.perform(Op.always('not claimed'):or_else(dial_ref:connected_op())), 'not claimed')
    end)

    assert_eq(connection_ref.owner, nil, 'Dial settlement should release unclaimed connection ownership')
    assert_truthy(connection_ref.handle.closed, 'Dial settlement should close unclaimed connection')
    listener:close('unclaimed test complete')
    listener:closed()
  end, { host = host })
end

-- A claimed Dial connection moves into the caller's scope and the Dial driver
-- terminates without retaining custody.
do
  local host = SimulatedHost.new({ sockets = true })
  fibers.run(function()
    local listener = socket.listen_inet('127.0.0.1', 0, { name = 'claimed-listener' })
    local address = listener:local_address()
    local dial = socket.dial_inet(address.host, address.port, { name = 'claimed-dial' })

    fibers.scope({ name = 'dial-target' }, function(target)
      local connection = dial:result()
      assert_eq(connection.owner, target:raw_region(), 'Dial result should move connection into caller scope')
      assert_eq(dial:closed(), true, 'Dial driver should finish after custody transfer')
    end)

    listener:close('claimed test complete')
    listener:closed()
  end, { host = host })
end

-- Dial results are single-claim.  A repeated result call terminates with a
-- structured closed value rather than waiting indefinitely.
do
  local host = SimulatedHost.new({ sockets = true })
  fibers.run(function()
    local listener = socket.listen_inet('127.0.0.1', 0, { name = 'single-claim-listener' })
    local address = listener:local_address()
    local dial = socket.dial_inet(address.host, address.port, { name = 'single-claim-dial' })
    local first = dial:result()
    local second, err = dial:result()
    assert_eq(second, nil)
    assert_truthy(HostError.is(err, 'closed'), 'repeated Dial result should be terminal')
    assert_eq(err.reason, 'connection already claimed')
    first:close('single claim test complete')
    listener:close('single claim test complete')
    listener:closed()
  end, { host = host })
end

-- Closing a Dial immediately after admission must terminate its result and
-- driver even if connection work has not yet had a scheduling turn.
do
  local host = SimulatedHost.new({ sockets = true })
  fibers.run(function()
    local listener = socket.listen_inet('127.0.0.1', 0, { name = 'early-close-listener' })
    local address = listener:local_address()
    local dial = socket.dial_inet(address.host, address.port, { name = 'early-close-dial' })
    assert_eq(dial:close('closed immediately'), true)
    assert_eq(dial:closed(), true)
    local connection, err = dial:result()
    assert_eq(connection, nil)
    assert_truthy(HostError.is(err, 'closed'), 'early-closed Dial should have a terminal result')
    listener:close('early close test complete')
    listener:closed()
  end, { host = host })
end

-- Closing a successful but unclaimed Dial makes success unavailable and
-- produces a structured terminal result rather than an indefinitely blocked one.
do
  local host = SimulatedHost.new({ sockets = true })
  fibers.run(function()
    local listener = socket.listen_inet('127.0.0.1', 0, { name = 'closed-result-listener' })
    local address = listener:local_address()
    local dial = socket.dial_inet(address.host, address.port, { name = 'closed-result-dial' })
    fibers.perform(dial.lifecycle:connected_state_op())

    assert_eq(dial:close('caller abandoned dial'), true)
    assert_eq(dial:closed(), true)
    local connection, err = dial:result()
    assert_eq(connection, nil)
    assert_truthy(HostError.is(err, 'closed'), 'closed unclaimed Dial should return a closed error')

    listener:close('closed result test complete')
    listener:closed()
  end, { host = host })
end

-- Normal scope settlement stops a Listener driver and settles queued
-- connections even when application code does not call close explicitly.
do
  local host = SimulatedHost.new({ sockets = true })
  local listener_ref, queued_ref
  fibers.run(function()
    listener_ref = socket.listen_inet('127.0.0.1', 0, {
      name = 'owner-seal-listener',
      accept_capacity = 1,
    })
    local address = listener_ref:local_address()
    local client = socket.dial_inet(address.host, address.port, { name = 'owner-seal-client' }):result()
    queued_ref = wait_for_queue(listener_ref, 1)[1].value
    client:close('owner-seal test complete')
    -- Return without closing the listener.
  end, { host = host })

  assert_truthy(listener_ref:host_handle().closed, 'scope settlement should close listener handle')
  assert_truthy(queued_ref.handle.closed, 'scope settlement should close queued connection')
end

-- Listener closure remains idempotent.
do
  local host = SimulatedHost.new({ sockets = true })
  fibers.run(function()
    local listener = socket.listen_inet('127.0.0.1', 0, { name = 'idempotent-listener' })
    assert_eq(listener:close('first close'), true)
    assert_eq(listener:close('second close'), true)
    assert_eq(listener:closed(), true)
  end, { host = host })
end

-- A listener close failure is retained as a scope-settlement failure.
do
  local host = SimulatedHost.new({ sockets = true })
  local create_listener = host.create_listener
  host.create_listener = function(self, address, opts)
    local handle, err = create_listener(self, address, opts)
    if not handle then
      return nil, err
    end
    handle._close = function()
      return nil, HostError.system('socket', 'close_listener', 'injected close failure', 'EIO')
    end
    return handle
  end

  local result = fibers.try_run(function()
    socket.listen_inet('127.0.0.1', 0, { name = 'failing-close-listener' })
  end, { host = host })
  assert_eq(result.ok, false, 'listener settlement failure should fail the scope')
  assert_truthy(tostring(result):match('injected close failure'), 'scope report should retain close failure')
end

-- A host adapter which throws instead of returning a structured HostError has
-- violated the driver contract.  Observers still receive a terminal result,
-- but the defect is retained as a scope-settlement failure.
do
  local host = SimulatedHost.new({ sockets = true })
  host.start_dial = function()
    error('injected dial adapter defect')
  end

  local result = fibers.try_run(function()
    local dial = socket.dial_inet('127.0.0.1', 9, { name = 'throwing-dial-host' })
    local connection, err = dial:result()
    assert_eq(connection, nil)
    assert_truthy(HostError.is(err, 'protocol'), 'adapter defect should publish a protocol result')
  end, { host = host })

  assert_eq(result.ok, false, 'adapter defect should fail scope settlement')
  assert_truthy(
    tostring(result):match('injected dial adapter defect'),
    'scope report should retain adapter defect'
  )
end

-- A host close implementation which throws is a protocol defect. It is
-- converted to a terminal lifecycle error and retained by settlement.
do
  local host = SimulatedHost.new({ sockets = true })
  local create_listener = host.create_listener
  host.create_listener = function(self, address, opts)
    local handle, err = create_listener(self, address, opts)
    if not handle then
      return nil, err
    end
    handle._close = function()
      error('injected throwing close defect')
    end
    return handle
  end

  local result = fibers.try_run(function()
    local listener = socket.listen_inet('127.0.0.1', 0, { name = 'throwing-close-listener' })
    local ok, err = listener:close('trigger throwing close')
    assert_eq(ok, nil)
    assert_truthy(HostError.is(err, 'protocol'))
  end, { host = host })

  assert_eq(result.ok, false, 'throwing close defect should fail settlement')
  assert_truthy(tostring(result):match('injected throwing close defect'))
end

-- A listener adapter which throws during acquisition publishes a fatal
-- lifecycle state, unblocks the driver and still fails the calling scope.
do
  local host = SimulatedHost.new({ sockets = true })
  host.create_listener = function()
    error('injected listen adapter defect')
  end

  local result = fibers.try_run(function()
    socket.listen_inet('127.0.0.1', 0, { name = 'throwing-listen-host' })
  end, { host = host })

  assert_eq(result.ok, false, 'listen adapter defect should fail the scope')
  assert_truthy(tostring(result):match('injected listen adapter defect'))
end

-- Socket option constructors snapshot caller-owned address and option tables.
do
  local host = SimulatedHost.new({ sockets = true })
  fibers.run(function()
    local address = socket.inet_address('127.0.0.1', 0)
    local opts = {
      name = 'snapshotted-listener',
      accept_capacity = 1,
    }
    local listen = socket.listen_op(address, opts)

    address.host = '203.0.113.99'
    opts.name = 'mutated-listener'
    opts.accept_capacity = 99

    local listener = fibers.perform(listen)
    assert_eq(listener.name, 'snapshotted-listener')
    assert_eq(listener.address.host, '127.0.0.1')
    assert_eq(listener.queue.capacity, 1)
    listener:close('snapshot test complete')
    listener:closed()
  end, { host = host })
end

print('tests/io/test_socket_hardening.lua: ok')

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
local file = require('fibers.file')
local socket = require('fibers.socket')
local SimulatedHost = require('tests.support.simulated_host')
local Handle = require('fibers.io.handle')
local HostError = require('fibers.io.error')
local IOAudit = require('fibers.diagnostics.io')
IOAudit.install(require('tests.support.io_audit_observer'))

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

-- A live pipe exposes both host handles and both reactor registrations. Scope
-- Closure retires and closes the complete tree, returning the runtime to a
-- clean audit state.
do
  IOAudit.reset_for_test()
  local during
  local result = fibers.try_run(function()
    local reader, writer = file.pipe({ name = 'audited-pipe' })
    writer:write('x')
    writer:flush()
    assert_eq(reader:read(1), 'x')
    during = fibers.current_runtime():io_audit()
    assert_truthy((during.counts.in_custody or 0) >= 2, 'pipe handles should be in Stream custody')
    assert_eq((during.counts.registered or 0), 2, 'directional pipe Streams should have two registrations')
  end, { host = SimulatedHost.new({ pipes = true }) })
  assert_truthy(result.ok, result:tostring())
  assert_eq(#result.runtime:io_audit().items, 0, 'Closure should leave no live I/O records')
  assert_truthy(result.runtime:assert_io_quiescent('audited pipe'))
end

-- Listener, accepted connection and Dial handles all enter custody and
-- leave no live registrations after normal closure.
do
  IOAudit.reset_for_test()
  local result = fibers.try_run(function(scope)
    local listener = socket.listen_ipv4('127.0.0.1', 0, { name = 'audited-listener' })
    local address = listener:local_address()
    local server = scope:spawn(function()
      local connection = assert(listener:accept())
      assert_truthy(connection:local_address())
      assert_truthy(connection:peer_address())
      connection:close('server complete')
    end, 'audited-server')
    local dial = socket.dial(address, { name = 'audited-dial' })
    local client = assert(dial:result())
    assert_truthy(client:peer_address())
    client:close('client complete')
    server:await()
    listener:close('listener complete')
    listener:closed()
  end, { host = SimulatedHost.new({ sockets = true }) })
  assert_truthy(result.ok, result:tostring())
  assert_eq(#result.runtime:io_audit().items, 0, 'socket tree should close completely')
  result.runtime:assert_io_quiescent('audited sockets')
end

-- Close failures remain visible as failed lifecycle records.
do
  IOAudit.reset_for_test()
  local err = HostError.system('handle', 'close', 'injected audit close failure', 'EIO')
  local handle = Handle.new({
    name = 'audit-close-failure',
    capabilities = { close = true },
    close = function()
      return nil, err
    end,
  })
  local ok, close_err = handle:close('test')
  assert_eq(ok, nil)
  assert_eq(close_err, err)
  local record = IOAudit.record(handle)
  assert_eq(record.state, 'close_failed')
  assert_eq(record.close_error, err)
end

print('tests/internal/test_io_audit.lua: ok')

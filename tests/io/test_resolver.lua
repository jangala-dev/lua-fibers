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
local socket = require('fibers.socket')
local Host = require('fibers.host')
local HostError = require('fibers.host.error')

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

-- Address constructors distinguish numeric addresses from unresolved names.
do
  local v4 = socket.ipv4_address('127.0.0.1', 80)
  assert_eq(v4.kind, 'inet4')
  assert_eq(v4.family, 'inet4')
  local v6 = socket.ipv6_address('::1', 443, { scope_id = 2 })
  assert_eq(v6.kind, 'inet6')
  assert_eq(v6.scope_id, 2)
  local name = socket.name_endpoint('example.test', 443)
  assert_eq(name.kind, 'name')
  assert_eq(socket.inet_address('example.test', 443).kind, 'name')
  assert_eq(socket.inet_address('192.0.2.1', 443).kind, 'inet4')
  assert_eq(socket.inet_address('2001:db8::1', 443).kind, 'inet6')
end

-- Manual resolution publishes an immutable, deduplicated numeric list.
do
  local host = Host.manual({
    resolver_records = {
      ['service.test'] = {
        { kind = 'inet6', host = '2001:db8::10' },
        { kind = 'inet4', host = '192.0.2.10' },
        { kind = 'inet4', host = '192.0.2.10' },
      },
    },
  })
  fibers.run(function()
    local endpoint = socket.name_endpoint('service.test', 8443)
    local resolve = socket.resolve_op(endpoint)
    endpoint.host = 'mutated.invalid'
    local query = fibers.perform(resolve)
    local addresses, err = query:result()
    assert_truthy(addresses, tostring(err))
    assert_eq(#addresses, 2)
    assert_eq(addresses[1].kind, 'inet6')
    assert_eq(addresses[1].port, 8443)
    assert_eq(addresses[2].kind, 'inet4')
    query:close('resolved')
  end, { host = host })
end

-- A losing resolver option performs no host work. Query admission and the
-- resolver driver effect occur only if the option commits.
do
  local host = Host.manual({
    resolver_records = {
      ['unused.test'] = {
        { kind = 'inet4', host = '192.0.2.20' },
      },
    },
  })
  local base_resolve = host.resolve
  local calls = 0
  host.resolve = function(self, endpoint, opts)
    calls = calls + 1
    return base_resolve(self, endpoint, opts)
  end
  fibers.run(function()
    local winner = fibers.perform(Op.always('preferred'):or_else(socket.resolve_name_op('unused.test', 80)))
    assert_eq(winner, 'preferred')
    assert_eq(calls, 0, 'losing resolver option must not call the host')
  end, { host = host })
end

-- Family filters are host resolver policy, not post-hoc socket inference.
do
  local host = Host.manual()
  fibers.run(function()
    local query = socket.resolve_name('localhost', 80, { family = 'inet4' })
    local addresses = assert(query:result())
    assert_eq(#addresses, 1)
    assert_eq(addresses[1].kind, 'inet4')
  end, { host = host })
end

-- Terminal resolution failure is a result value and the success option is
-- refutable, allowing result_op's certified fallback to commit.
do
  local host = Host.manual({ resolver_records = {} })
  fibers.run(function()
    local query = socket.resolve_name('missing.test', 80)
    local addresses, err = query:result()
    assert_eq(addresses, nil)
    assert_truthy(HostError.is(err, 'system'))
    assert_eq(err.code, 'EAI_NONAME')
  end, { host = host })
end

-- A resolved address can be used directly by the existing Dial facility.
do
  local host = Host.manual({
    sockets = true,
    pipes = true,
    resolver_records = {
      ['echo.test'] = {
        { kind = 'inet4', host = '127.0.0.1' },
      },
    },
  })
  fibers.run(function(scope)
    local listener = assert(socket.listen_ipv4('127.0.0.1', 0))
    local actual = listener:local_address()
    host.resolver_records['echo.test'][1].port = actual.port

    local server = scope:spawn(function()
      local connection = assert(listener:accept())
      assert_eq(connection:read(1), 'x')
      connection:close('server complete')
    end, 'resolver-echo-server')

    local query = socket.resolve_name('echo.test', actual.port)
    local addresses = assert(query:result())
    local dial = socket.dial(addresses[1])
    local connection = assert(dial:result())
    connection:write('x')
    connection:flush()
    connection:close('client complete')
    server:await()
    listener:close('test complete')
  end, { host = host })
end

-- Host names are not silently passed to the numeric socket backend.
do
  local ok, err = pcall(function()
    socket.dial_inet_op('example.test', 443)
  end)
  assert_eq(ok, false)
  assert_truthy(string.find(tostring(err), 'use socket.resolve', 1, true) ~= nil)
end

print('tests/io/test_resolver.lua: ok')

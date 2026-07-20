package.path = table.concat({
  './src/?.lua', './src/?/init.lua', './src/?/?.lua',
  './reference/?.lua', './reference/?/init.lua', './reference/?/?.lua',
  './?.lua', './?/init.lua', './?/?.lua', package.path,
}, ';')

local Host = require('fibers.host')
local socket = require('fibers.socket')
local Contract = require('tests.support.socket_provider_contract')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'values differ') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual), 2)
  end
end

local function assert_truthy(value, message)
  if not value then
    error(message or 'expected truthy value', 2)
  end
end

-- Address values have stable identity, display and wildcard laws independent of
-- the selected provider.
do
  local v4 = socket.ipv4_address('127.0.0.1', 80)
  local v4_copy = socket.ipv4_address('127.0.0.1', 80)
  local v6 = socket.ipv6_address('::1', 80)
  assert_truthy(socket.address_equal(v4, v4_copy))
  assert_eq(socket.address_equal(v4, v6), false)
  assert_eq(socket.format_address(v4), '127.0.0.1:80')
  assert_eq(socket.format_address(v6), '[::1]:80')
  assert_truthy(socket.address_is_wildcard(socket.ipv4_address('0.0.0.0', 0)))
  assert_truthy(socket.address_is_wildcard(socket.ipv6_address('::', 0)))
  assert_eq(socket.address_with_port(v4, 443).port, 443)
end

-- ManualHost is the complete deterministic provider oracle.
do
  local host = Host.manual({ sockets = true, pipes = true })
  Contract.exercise('manual-ipv4', host, socket.ipv4_address('127.0.0.1', 0), { require_client_local = true })
  Contract.exercise('manual-ipv6', host, socket.ipv6_address('::1', 0), { require_client_local = true })
  Contract.exercise('manual-unix', host, socket.unix_address('/manual/provider-matrix'))
  Contract.close_host(host)
end

-- The pure host declares the complete stream-socket capability matrix as false
-- and returns a structured unsupported result.
do
  local host = Host.pure({
    now = function()
      return 0
    end,
    sleep = function()
      return true
    end,
  })
  assert_eq(host.capabilities.socket, false)
  assert_eq(host.capabilities.socket_ipv4, false)
  assert_eq(host.capabilities.socket_ipv6, false)
  assert_eq(host.capabilities.socket_unix, false)
  Contract.expect_unsupported('pure', host, socket.ipv4_address('127.0.0.1', 0))
end

-- Optional providers must explicitly declare the family matrix. Providers which
-- presently implement only readiness, pipes or datagrams remain honest rather
-- than being inferred to support stream sockets.
for _, spec in ipairs({
  { module = 'fibers.host.luaposix', name = 'luaposix' },
  { module = 'fibers.host.nixio', name = 'nixio' },
  { module = 'fibers.host.luajit_linux', name = 'luajit_linux' },
  { module = 'fibers.host.cffi_linux', name = 'cffi_linux' },
}) do
  local ok, provider = pcall(require, spec.module)
  if ok and provider and type(provider.is_supported) == 'function' and provider.is_supported() then
    local host = provider.new()
    assert_truthy(type(host.capabilities.socket) == 'boolean', spec.name .. ' must declare socket capability')
    assert_truthy(type(host.capabilities.socket_ipv4) == 'boolean', spec.name .. ' must declare IPv4')
    assert_truthy(type(host.capabilities.socket_ipv6) == 'boolean', spec.name .. ' must declare IPv6')
    assert_truthy(type(host.capabilities.socket_unix) == 'boolean', spec.name .. ' must declare Unix sockets')
    if host.capabilities.socket == false then
      Contract.expect_unsupported(spec.name, host, socket.ipv4_address('127.0.0.1', 0))
    else
      if host.capabilities.socket_ipv4 then
        Contract.exercise(spec.name .. '-ipv4', host, socket.ipv4_address('127.0.0.1', 0))
      end
      if host.capabilities.socket_ipv6 then
        Contract.exercise(spec.name .. '-ipv6', host, socket.ipv6_address('::1', 0))
      end
      if host.capabilities.socket_unix then
        local path = os.tmpname() .. '-' .. spec.name .. '.sock'
        os.remove(path)
        Contract.exercise(spec.name .. '-unix', host, socket.unix_address(path))
        os.remove(path)
      end
    end
    Contract.close_host(host)
  end
end

print('tests/io/test_socket_provider_matrix.lua: ok')

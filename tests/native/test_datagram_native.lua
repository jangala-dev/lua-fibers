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


local ok_mod, LinuxHost = pcall(require, 'fibers.io.luajit_linux')
if not ok_mod or not LinuxHost.is_supported() then
  return { status = 'skip', reason = 'LuaJIT FFI Linux datagram host unavailable' }
end

local function exchange(host, family)
  local report = fibers.try_run(function()
    local left
    local right
    if family == 'inet6' then
      left = assert(socket.udp_ipv6('::1', 0))
      right = assert(socket.udp_ipv6('::1', 0))
    else
      left = assert(socket.udp_ipv4('127.0.0.1', 0))
      right = assert(socket.udp_ipv4('127.0.0.1', 0))
    end
    left:send_to('abcdef', right:local_address())
    left:flush()
    local packet = assert(right:receive_from({ max_size = 3 }))
    assert(packet.data == 'abc')
    assert(packet.truncated == true)
    assert(packet.original_size == 6)
    left:close('native exchange complete')
    right:close('native exchange complete')
    left:closed()
    right:closed()
  end, { host = host, max_iterations = 50000 })
  assert(report.ok, tostring(report.primary or report.error))
end

local host = LinuxHost.new()
assert(host:feature('datagram') == true)
exchange(host, 'inet4')
exchange(host, 'inet6')
host:close()
print('tests/native/test_datagram_native.lua: ok')

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

local Common = require('tests.hosts.common')

local ok_host, PosixHost = pcall(require, 'fibers.host.luaposix')
Common.assert_truthy(ok_host, 'luaposix host module should be require-able')
if not PosixHost.is_supported() then
  return Common.skip('tests/hosts/test_fd_luaposix.lua', 'luaposix host not available')
end

local ok_fd, Fd = pcall(require, 'fibers.host.fd_luaposix')
Common.assert_truthy(ok_fd, 'fd_luaposix module should be require-able')
if not Fd.is_supported() then
  local _, reason = Fd.is_supported()
  return Common.skip(
    'tests/hosts/test_fd_luaposix.lua',
    reason or 'fd luaposix backend not available'
  )
end

local host = PosixHost.new()
Fd = host.fd
Common.assert_truthy(Fd, 'luaposix host should expose paired fd backend')
local ok, err = pcall(function()
  Common.handle_stream_pipe_smoke('fd_luaposix:stream-pipe', host, Fd)
end)
Common.close_quietly(host)
if not ok then
  error(err, 0)
end

print('tests/hosts/test_fd_luaposix.lua: ok')

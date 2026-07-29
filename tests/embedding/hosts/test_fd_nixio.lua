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

local Common = require('tests.embedding.hosts.common')

local ok_host, NixioHost = pcall(require, 'fibers.io.nixio')
Common.assert_truthy(ok_host, 'nixio host module should be require-able')
if not NixioHost.is_supported() then
  return Common.skip('tests/hosts/test_fd_nixio.lua', 'nixio host not available')
end

local host = NixioHost.new()
local Fd = host.fd
Common.assert_truthy(Fd, 'nixio host should expose paired fd backend')
local ok, err = pcall(function()
  Common.handle_stream_pipe_smoke('fd_nixio:stream-pipe', host, Fd)
end)
Common.close_quietly(host)
if not ok then
  error(err, 0)
end

print('tests/hosts/test_fd_nixio.lua: ok')

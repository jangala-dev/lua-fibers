package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

local Common = require('tests.hosts.common')

local ok_host, NixioHost = pcall(require, 'fibers.host.nixio')
Common.assert_truthy(ok_host, 'nixio host module should be require-able')
if not NixioHost.is_supported() then
  return Common.skip('tests/hosts/test_fd_nixio.lua', 'nixio host not available')
end

local ok_fd, Fd = pcall(require, 'fibers.host.fd_nixio')
Common.assert_truthy(ok_fd, 'fd_nixio module should be require-able')
if not Fd.is_supported() then
  local _, reason = Fd.is_supported()
  return Common.skip('tests/hosts/test_fd_nixio.lua', reason or 'fd nixio backend not available')
end

local host = NixioHost.new()
Fd = host.fd
Common.assert_truthy(Fd, 'nixio host should expose paired fd backend')
local ok, err = pcall(function()
  Common.handle_stream_pipe_smoke('fd_nixio:stream-pipe', host, Fd)
end)
Common.close_quietly(host)
if not ok then
  error(err, 0)
end

print('tests/hosts/test_fd_nixio.lua: ok')

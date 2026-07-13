package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

local Common = require('tests.hosts.common')

local ok_host, CffiHost = pcall(require, 'fibers.host.cffi_linux')
Common.assert_truthy(ok_host, 'cffi linux host module should be require-able')
if not CffiHost.is_supported() then
  local _, reason = CffiHost.is_supported()
  return Common.skip('tests/hosts/test_fd_cffi.lua', reason or 'cffi Linux host not available')
end

local ok_fd, Fd = pcall(require, 'fibers.host.fd_cffi')
Common.assert_truthy(ok_fd, 'fd_cffi module should be require-able')
if not Fd.is_supported() then
  local _, reason = Fd.is_supported()
  return Common.skip('tests/hosts/test_fd_cffi.lua', reason or 'fd cffi backend not available')
end

local host = CffiHost.new()
Fd = host.fd
Common.assert_truthy(Fd, 'cffi host should expose paired fd backend')
local ok, err = pcall(function()
  Common.handle_stream_pipe_smoke('fd_cffi:stream-pipe', host, Fd)
end)
Common.close_quietly(host)
if not ok then
  error(err, 0)
end

print('tests/hosts/test_fd_cffi.lua: ok')

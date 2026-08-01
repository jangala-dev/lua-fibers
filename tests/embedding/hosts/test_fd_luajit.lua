package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

local External = require('fibers.embed.external')
local Common = require('tests.embedding.hosts.common')
local fibers = require('fibers')
local FibersRuntime = require('fibers.runtime')
local FibersReadiness = require('fibers.io.readiness')

local ok_host, LinuxHost = pcall(require, 'fibers.io.luajit_linux')
Common.assert_truthy(ok_host, 'luajit linux host module should be require-able')
if not LinuxHost.is_supported() then
  return Common.skip('tests/hosts/test_fd_luajit.lua', 'LuaJIT FFI Linux host not available')
end

local host = LinuxHost.new()
local Fd = host.fd
Common.assert_truthy(Fd, 'luajit host should expose paired fd backend')
if not Fd.is_supported() then
  local _, reason = Fd.is_supported()
  return Common.skip('tests/hosts/test_fd_luajit.lua', reason or 'fd ffi backend not available')
end
local r, w = Fd.pipe({ host = host, name = 'fd-pipe' })
local ok, err = pcall(function()
  Common.assert_truthy(type(r.read) == 'function', 'read handle should expose read')
  Common.assert_truthy(type(w.write) == 'function', 'write handle should expose write')
  local n, werr = w:write('x')
  Common.assert_eq(n, 1, 'fd write should write one byte')
  local rt = FibersRuntime.new({ host = host })
  local src = FibersReadiness.new(r:readiness_key(), 'read', 'fd-handle-readiness')
  local seen
  rt:spawn_raw(function()
    seen = rt:perform(src:readable_op())
  end, 'fd-readiness')
  local st = External.drive(rt, { host = host, max_iterations = 40 })
  Common.assert_status(st, 'found', 'fd readiness should be delivered')
  Common.assert_eq(seen, true, 'fd readiness result')
  local b, rerr = r:read(1)
  Common.assert_eq(b, 'x', 'fd read should return written byte')
end)
r:close('test')
w:close('test')
host:close()
if not ok then
  error(err, 0)
end

local host2 = LinuxHost.new()
local ok2, err2 = pcall(function()
  Common.handle_stream_pipe_smoke('fd_luajit:stream-pipe', host2, Fd)
end)
Common.close_quietly(host2)
if not ok2 then
  error(err2, 0)
end

print('tests/hosts/test_fd_luajit.lua: ok')

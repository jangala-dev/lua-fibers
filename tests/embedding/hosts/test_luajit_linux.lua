package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

local Common = require('tests.embedding.hosts.common')
local fibers = require('fibers')
local FibersRuntime = require('fibers.runtime')

local ok_mod, LinuxHost = pcall(require, 'fibers.io.luajit_linux')
Common.assert_truthy(ok_mod, 'luajit linux host module should be require-able')
Common.assert_truthy(type(LinuxHost.is_supported) == 'function', 'luajit host should expose is_supported')
Common.assert_truthy(type(LinuxHost.new) == 'function', 'luajit host should expose new')

if not LinuxHost.is_supported() then
  return Common.skip('tests/hosts/test_luajit_linux.lua', 'LuaJIT FFI Linux backend not available')
end

local ok_ffi, ffi = pcall(require, 'ffi')
if not ok_ffi or type(ffi) ~= 'table' then
  return Common.skip('tests/hosts/test_luajit_linux.lua', 'ffi module not available')
end

local BitOps = require('fibers.io.bitops')
local bit, bit_reason = BitOps.resolve()
if not bit then
  return Common.skip('tests/hosts/test_luajit_linux.lua', bit_reason or 'bit operations unavailable')
end

-- The unified provider exposes POSIX mechanisms through the common host.

local FfiSupport = require('tests.support.ffi_linux')
if not FfiSupport.available then
  return Common.skip('tests/hosts/test_luajit_linux.lua', FfiSupport.reason)
end

local function make_pipe()
  return FfiSupport.make_pipe(Common.assert_eq)
end

local function make_regular_file()
  return FfiSupport.make_regular_file(Common.assert_truthy)
end

local function with_host_pipe(label, fn)
  local host = LinuxHost.new()
  local pipe = make_pipe()
  local ok, err = pcall(function()
    fn(label, host, pipe)
  end)
  Common.cleanup(host, pipe)
  if not ok then
    error(err, 0)
  end
end

with_host_pipe('luajit_linux:readiness', Common.readiness_smoke)
with_host_pipe('luajit_linux:write-readiness', Common.write_readiness_smoke)
with_host_pipe('luajit_linux:readiness-beats-timeout', Common.readiness_beats_timeout_smoke)
with_host_pipe('luajit_linux:timeout-beats-unready', Common.timeout_beats_unready_smoke)

-- poll(2) reports regular files as immediately readable.
do
  local host = LinuxHost.new()
  local file = make_regular_file()
  local ok, err = pcall(function()
    Common.ready_source_smoke('luajit_linux:unpollable-regular-file', host, file.read_key, 'read')
  end)
  Common.cleanup(host, file)
  if not ok then
    error(err, 0)
  end
end

-- Block-after-close should fail clearly rather than using a stale epoll fd.
do
  local host = LinuxHost.new()
  host:close()
  local ok, err = pcall(function()
    host:block(FibersRuntime.new({ host = host }), {}, { tag = 'pending' }, {})
  end)
  Common.assert_eq(ok, false, 'block after close should fail')
  Common.assert_truthy(
    string.find(tostring(err), 'host is closed', 1, true) ~= nil,
    'block-after-close error should be clear'
  )
end

-- Close should be idempotent; hosts are often torn down during error paths.
do
  local host = LinuxHost.new()
  host:close()
  host:close()
end

-- Real kernel readiness is validated separately from portable host simulation.  The
-- portable semantic suite covers deterministic option
-- semantics; combining it with wall-clock readiness races makes that suite
-- needlessly nondeterministic.
local socket_host = LinuxHost.new()
if type(rawget(_G, 'jit')) ~= 'table' then
  Common.assert_eq(
    socket_host:feature('resolver'),
    false,
    'compatibility ffi must not advertise unsafe getaddrinfo traversal'
  )
end
Common.native_socket_smoke('luajit_linux', socket_host)
Common.native_datagram_smoke('luajit_linux', socket_host)
-- The texlua test environment exposes a compatibility ffi implementation
-- but not LuaJIT itself; its getaddrinfo pointer lifetime is unsafe. Exercise
-- the native resolver here only on the intended LuaJIT runtime.
if type(rawget(_G, 'jit')) == 'table' then
  Common.native_resolver_smoke('luajit_linux', socket_host)
end
socket_host:close()

print('tests/hosts/test_luajit_linux.lua: ok')

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
local fibers = require('fibers')
local FibersRuntime = require('fibers.runtime')

local ok_mod, LinuxHost = pcall(require, 'fibers.host.cffi_linux')
Common.assert_truthy(ok_mod, 'cffi linux host module should be require-able')
Common.assert_truthy(
  type(LinuxHost.is_supported) == 'function',
  'cffi linux host should expose is_supported'
)
Common.assert_truthy(type(LinuxHost.new) == 'function', 'cffi linux host should expose new')

local supported, support_reason = LinuxHost.is_supported()
if not supported then
  return Common.skip(
    'tests/hosts/test_cffi_linux.lua',
    'cffi Linux backend not available: '
      .. tostring(
        support_reason
          or (LinuxHost.support_reason and LinuxHost.support_reason())
          or 'unknown reason'
      )
  )
end

local ok_cffi, ffi = pcall(require, 'cffi')
if not ok_cffi or type(ffi) ~= 'table' then
  return Common.skip('tests/hosts/test_cffi_linux.lua', 'cffi module not available')
end

local arch = ffi.arch or (rawget(_G, 'jit') and rawget(_G, 'jit').arch)
local size = ffi.sizeof('struct epoll_event')
if arch == 'x64' or arch == 'x86' then
  Common.assert_eq(size, 12, 'epoll_event ABI size on ' .. tostring(arch))
else
  Common.assert_truthy(size >= 12, 'epoll_event ABI size should be plausible')
end

local CffiSupport = require('tests.support.cffi_linux')
if not CffiSupport.available then
  return Common.skip('tests/hosts/test_cffi_linux.lua', CffiSupport.reason)
end

local function make_pipe()
  return CffiSupport.make_pipe(Common.assert_eq)
end

local function make_regular_file()
  return CffiSupport.make_regular_file(Common.assert_truthy)
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

with_host_pipe('cffi_linux:readiness', Common.readiness_smoke)
with_host_pipe('cffi_linux:write-readiness', Common.write_readiness_smoke)
with_host_pipe('cffi_linux:readiness-beats-timeout', Common.readiness_beats_timeout_smoke)
with_host_pipe('cffi_linux:timeout-beats-unready', Common.timeout_beats_unready_smoke)

do
  local host = LinuxHost.new()
  local file = make_regular_file()
  local ok, err = pcall(function()
    Common.ready_source_smoke('cffi_linux:unpollable-regular-file', host, file.read_key, 'read')
    Common.assert_truthy(
      host.unpollable[file.read_key],
      'regular file fd should be marked unpollable'
    )
  end)
  Common.cleanup(host, file)
  if not ok then
    error(err, 0)
  end
end

do
  local host = LinuxHost.new({ maxevents = 0 })
  Common.assert_eq(host.maxevents, 1, 'maxevents should be clamped to at least one')
  host:close()
end

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

do
  local host = LinuxHost.new()
  host:close()
  host:close()
end

print('tests/hosts/test_cffi_linux.lua: ok')

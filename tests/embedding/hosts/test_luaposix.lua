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

local ok_mod, PosixHost = pcall(require, 'fibers.io.luaposix')
Common.assert_truthy(ok_mod, 'luaposix host module should be require-able')
Common.assert_truthy(type(PosixHost.is_supported) == 'function', 'luaposix host should expose is_supported')
Common.assert_truthy(type(PosixHost.new) == 'function', 'luaposix host should expose new')

if not PosixHost.is_supported() then
  return Common.skip('tests/hosts/test_luaposix.lua', 'luaposix backend not available')
end

local PosixSupport = require('tests.support.posix_linux')
if not PosixSupport.available then
  return Common.skip('tests/hosts/test_luaposix.lua', PosixSupport.reason)
end

local function make_pipe()
  return PosixSupport.make_pipe(Common.assert_truthy)
end

local function with_host_pipe(label, fn)
  local host = PosixHost.new()
  local pipe = make_pipe()
  local ok, err = pcall(function()
    fn(label, host, pipe)
  end)
  Common.cleanup(host, pipe)
  if not ok then
    error(err, 0)
  end
end

with_host_pipe('luaposix:readiness', Common.readiness_smoke)
with_host_pipe('luaposix:write-readiness', Common.write_readiness_smoke)
with_host_pipe('luaposix:readiness-beats-timeout', Common.readiness_beats_timeout_smoke)
with_host_pipe('luaposix:timeout-beats-unready', Common.timeout_beats_unready_smoke)

if os.getenv('FIBERS_MACHINE') ~= 'reference' then
  local datagram_host = PosixHost.new()
  if datagram_host.capabilities.datagram then
    Common.native_datagram_smoke('luaposix', datagram_host)
  end
  if datagram_host.capabilities.resolver then
    require('tests.support.resolver_provider_contract').exercise('luaposix', datagram_host)
  end
  datagram_host:close()
end

print('tests/hosts/test_luaposix.lua: ok')

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
local FibersRuntime = require('fibers.runtime')
local FibersReadiness = require('fibers.io.readiness')
local AutoIO = require('fibers.io.auto')
local WaitSet = require('fibers.embed.wait_set')

local function fail(msg)
  error(msg, 2)
end
local function assert_truthy(v, msg)
  if not v then
    fail(msg or 'expected truthy')
  end
end
local function assert_eq(a, b, msg)
  if a ~= b then
    fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a))
  end
end

-- The LuaJIT host must not load a merely same-named `ffi` module on a
-- non-LuaJIT VM (TexLua and LuaJITTeX may provide one).
do
  if type(rawget(_G, 'jit')) ~= 'table' then
    local old_ffi, loaded = package.preload.ffi, false
    package.loaded['fibers.io.luajit_linux'] = nil
    package.loaded.ffi = nil
    package.preload.ffi = function()
      loaded = true
      error('non-LuaJIT ffi must not be loaded')
    end
    local ok, module = pcall(require, 'fibers.io.luajit_linux')
    package.preload.ffi = old_ffi
    package.loaded.ffi = nil
    assert_truthy(ok, 'luajit host should remain require-able outside LuaJIT')
    assert_truthy(not loaded, 'luajit host should probe jit before requiring ffi')
    local supported = module.is_supported()
    assert_truthy(not supported, 'luajit host should report unsupported outside LuaJIT')
  end
end

-- Optional Linux host modules must be require-able even when their platform
-- dependencies are unavailable under the test interpreter.
do
  local ok1, ffi_host = pcall(require, 'fibers.io.luajit_linux')
  assert_truthy(ok1, 'luajit linux host module should be require-able')
  assert_truthy(type(ffi_host.is_supported) == 'function', 'luajit host should expose is_supported')
  assert_truthy(type(ffi_host.new) == 'function', 'luajit host should expose new')

  local ok2, nixio_host = pcall(require, 'fibers.io.nixio')
  assert_truthy(ok2, 'nixio linux host module should be require-able')
  assert_truthy(type(nixio_host.is_supported) == 'function', 'nixio host should expose is_supported')
  assert_truthy(type(nixio_host.new) == 'function', 'nixio host should expose new')

  local ok3, posix_host = pcall(require, 'fibers.io.luaposix')
  assert_truthy(ok3, 'luaposix host module should be require-able')
  assert_truthy(type(posix_host.is_supported) == 'function', 'luaposix host should expose is_supported')
  assert_truthy(type(posix_host.new) == 'function', 'luaposix host should expose new')

  local ok4, cffi_host = pcall(require, 'fibers.io.cffi_linux')
  assert_truthy(ok4, 'cffi linux host module should be require-able')
  assert_truthy(type(cffi_host.is_supported) == 'function', 'cffi host should expose is_supported')
  assert_truthy(type(cffi_host.new) == 'function', 'cffi host should expose new')
end

-- Readiness waits must retain both the consumer Readiness resource and the host-facing key,
-- otherwise host adapters cannot inject readiness arrivals back through the
-- Runtime boundary.
do
  local rt = FibersRuntime.new()
  local src = FibersReadiness.new(42, 'read'):label('fd-42')
  rt:spawn_raw(function()
    rt:perform(src:readable_op())
  end)
  local st = rt:run()
  assert_eq(st.tag, 'pending')
  local waits = (st.interests or {})
  local rw = WaitSet.readiness_waits(waits)
  assert_eq(#rw, 1, 'one readiness wait expected')
  assert_eq(rw[1].resource, src, 'interest should carry resource object')
  assert_eq(rw[1].feed.resource, src, 'interest should carry a feed for the resource')
  assert_eq(rw[1].readiness_key, 42, 'wait should carry original readiness key')
  assert_eq(rw[1].mode, 'read', 'wait should carry readiness mode')
end

-- Host constructor helpers should be present.  They may raise if the optional
-- backend is not available; is_supported on the module is the probe.
do
  assert_truthy(type(AutoIO.luajit_linux) == 'function', 'AutoIO.luajit_linux helper should exist')
  assert_truthy(type(AutoIO.nixio) == 'function', 'AutoIO.nixio helper should exist')
  assert_truthy(type(AutoIO.luaposix) == 'function', 'AutoIO.luaposix helper should exist')
  assert_truthy(type(AutoIO.cffi_linux) == 'function', 'AutoIO.cffi_linux helper should exist')
end


-- Fd.new owns a raw descriptor once wrapping begins.  If descriptor
-- configuration fails, the wrapping path closes it exactly once; callers must
-- not repeat raw cleanup after Fd.new reports the failure.
do
  local Posix = require('fibers.io.posix')
  local Address = require('fibers.net.address')
  local closes = 0
  local binding = {
    name = 'ownership_probe',
    family = 'ownership_probe',
    time = { now = function() return 0 end, sleep = function() return true end },
    poll = { wait = function() return {} end },
    errors = {},
    fd = {
      supported = function() return true end,
      validate = function(value) return value end,
      close = function()
        closes = closes + 1
        return true
      end,
      set_nonblocking = function() return nil, 22, 'configuration failed' end,
    },
    net = {
      supports = function() return true end,
      encode = function() return { family = 'inet4', native = {} } end,
      decode = function(value) return value end,
      is_unix = function() return false end,
      open = function() return {} end,
      query = function() return nil end,
      bind = function() return true end,
      listen = function() return true end,
      connect = function() return true end,
      socket_error = function() return 0 end,
    },
  }
  local host = Posix.define(binding).new()
  local listener, err = host:create_listener(Address.ipv4('127.0.0.1', 0), {})
  assert_truthy(listener == nil and err ~= nil, 'configuration failure should reject listener')
  assert_eq(closes, 1, 'failed descriptor wrapping must close the raw value exactly once')

  binding.fd.set_nonblocking = function() return true end
  binding.fd.close = function()
    closes = closes + 1
    return nil, 5, 'close failed'
  end
  binding.net.bind = function() return nil, 98, 'bind failed' end
  local failed, setup_err = host:create_listener(Address.ipv4('127.0.0.1', 0), {})
  assert_truthy(failed == nil and setup_err and setup_err.kind == 'protocol',
    'socket setup should retain a simultaneous close failure')
  assert_truthy(type(setup_err.errors) == 'table' and #setup_err.errors == 2,
    'socket setup error should contain primary and cleanup failures')
  assert_eq(closes, 2, 'socket setup cleanup should attempt one close')
end

print('tests/test_host_linux.lua: ok')

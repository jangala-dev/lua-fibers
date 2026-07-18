-- Complete Linux host family using LuaJIT FFI.
--
-- Provides monotonic time, blocking via epoll/nanosleep, readiness delivery, and
-- the paired numeric-fd HostHandle implementation.

local Common = require('fibers.host._linux_epoll_ffi_common')

local function unsupported(reason)
  return Common.unsupported('fibers.host.luajit_linux', reason)
end

local ok_ffi, ffi = pcall(require, 'ffi')
if not ok_ffi or type(ffi) ~= 'table' then
  return unsupported('LuaJIT ffi not available')
end

local BitOps = require('fibers.internal.bitops')
local bit, bit_error = BitOps.resolve()
if not bit then
  return unsupported(bit_error)
end

return Common.new({
  name = 'luajit_linux',
  error_prefix = 'fibers.host.luajit_linux',
  ffi = ffi,
  bit = bit,
  C = ffi.C,
  fd_module = 'fibers.host.fd_luajit',
  -- Some non-LuaJIT interpreters expose a compatibility `ffi` sufficient for
  -- numeric descriptors but unsafe for getaddrinfo linked-list traversal.
  resolver_enabled = type(rawget(_G, 'jit')) == 'table',
})

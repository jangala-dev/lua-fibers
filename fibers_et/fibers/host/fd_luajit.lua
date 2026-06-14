-- Numeric fd HostHandle implementation using LuaJIT FFI.
--
-- This module is explicit: it only uses LuaJIT's ffi provider and does not
-- fall back to cffi.

local Common = require('fibers.host._fd_ffi_common')

local function unsupported(reason)
  return Common.unsupported('fibers.host.fd_luajit', reason)
end

local ok_ffi, ffi = pcall(require, 'ffi')
if not ok_ffi or type(ffi) ~= 'table' then return unsupported('LuaJIT ffi not available') end

local bit = rawget(_G, 'bit')
if not bit then return unsupported('LuaJIT bit operations not available') end

return Common.new {
  name = 'fd_luajit',
  error_prefix = 'fibers.host.fd_luajit',
  ffi = ffi,
  bit = bit,
  C = ffi.C,
}

-- Numeric fd HostHandle implementation using the cffi module.
--
-- This module is explicit: it only uses cffi and does not fall back to LuaJIT
-- ffi.

local Common = require('fibers.host._fd_ffi_common')

local function unsupported(reason)
  return Common.unsupported('fibers.host.fd_cffi', reason)
end

local ok_cffi, ffi = pcall(require, 'cffi')
if not ok_cffi or type(ffi) ~= 'table' then
  return unsupported('cffi module not available')
end

local BitOps = require('fibers.internal.bitops')
local bit, bit_error = BitOps.resolve()
if not bit then
  return unsupported(bit_error)
end

return Common.new({
  name = 'fd_cffi',
  error_prefix = 'fibers.host.fd_cffi',
  ffi = ffi,
  bit = bit,
  C = ffi.C,
})

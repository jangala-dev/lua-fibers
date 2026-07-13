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

local bit = rawget(_G, 'bit') or rawget(_G, 'bit32')
if not bit then
  local ok_bit32, bit32_mod = pcall(require, 'bit32')
  if ok_bit32 then
    bit = bit32_mod
  end
end
if not bit then
  return unsupported('bit or bit32 operations not available')
end

return Common.new({
  name = 'fd_cffi',
  error_prefix = 'fibers.host.fd_cffi',
  ffi = ffi,
  bit = bit,
  C = ffi.C,
})

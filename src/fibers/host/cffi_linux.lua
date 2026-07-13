-- Complete Linux host family using the cffi module.
--
-- Provides monotonic time, blocking via epoll/nanosleep, readiness delivery, and
-- the paired numeric-fd HostHandle implementation.

local Common = require('fibers.host._linux_epoll_ffi_common')

local function unsupported(reason)
  return Common.unsupported('fibers.host.cffi_linux', reason)
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
  name = 'cffi_linux',
  error_prefix = 'fibers.host.cffi_linux',
  ffi = ffi,
  bit = bit,
  C = ffi.C,
  fd_module = 'fibers.host.fd_cffi',
})

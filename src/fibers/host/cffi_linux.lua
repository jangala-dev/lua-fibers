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

local BitOps = require('fibers.internal.bitops')
local bit, bit_error = BitOps.resolve()
if not bit then
  return unsupported(bit_error)
end

return Common.new({
  name = 'cffi_linux',
  error_prefix = 'fibers.host.cffi_linux',
  ffi = ffi,
  bit = bit,
  C = ffi.C,
  fd_module = 'fibers.host.fd_cffi',
})

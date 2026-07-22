-- Load one complete Linux FFI host family.

local Common = require('fibers.host._linux_epoll_ffi_common')
local BitOps = require('fibers.internal.bitops')

local M = {}

function M.load(module_name, name, opts)
  local prefix = 'fibers.host.' .. name
  local ok, ffi = pcall(require, module_name)
  if not ok or type(ffi) ~= 'table' then
    return Common.unsupported(prefix, module_name .. ' module not available')
  end
  local bit, reason = BitOps.resolve()
  if not bit then
    return Common.unsupported(prefix, reason)
  end
  opts = opts or {}
  opts.name, opts.error_prefix, opts.ffi, opts.bit, opts.C = name, prefix, ffi, bit, ffi.C
  return Common.new(opts)
end

return M

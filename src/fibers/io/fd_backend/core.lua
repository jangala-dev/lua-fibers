-- fibers/io/fd_backend/core.lua
--
-- Core glue for fd-backed StreamBackend implementations.
--
-- This module owns the public FdBackend shape and semantics.
-- Platform backends provide only low-level primitives; build_backend
-- wires those into a concrete { new, is_supported } module.
--
---@module 'fibers.io.fd_backend.core'

local poller = require 'fibers.io.poller'

---@class FdBackend
---@field filename string|nil  -- optional filename for diagnostics
---@field _fd integer|nil      -- underlying OS file descriptor (or nil if closed)
---@field _ops table           -- low-level operations table (see build_backend)

local FdBackend = {}
FdBackend.__index = FdBackend

----------------------------------------------------------------------
-- Public methods (contract lives here)
----------------------------------------------------------------------

--- Backend kind identifier.
---@return '"fd"'
function FdBackend:kind()
  return "fd"
end

--- Underlying file descriptor number, or nil if closed.
---@return integer|nil
function FdBackend:fileno()
  return self._fd
end

--- Read up to max bytes as a Lua string.
---
--- Semantics:
---   * s == nil, err == nil      : would block
---   * s == nil, err ~= nil      : hard error
---   * s == ""                   : EOF
---   * s ~= ""                   : data
---
---@param max? integer
---@return string|nil s, string|nil err
function FdBackend:read_string(max)
  if not self._fd then
    return nil, "closed"
  end

  max = max or 4096
  if max <= 0 then
    -- Matches existing posix/ffi backends.
    return "", nil
  end

  return self._ops.read(self._fd, max)
end

--- Write a Lua string.
---
--- Semantics:
---   * n == nil, err == nil      : would block
---   * n == nil, err ~= nil      : hard error
---   * n >= 0                    : bytes written
---
---@param str string
---@return integer|nil n, string|nil err
function FdBackend:write_string(str)
  if not self._fd then
    return nil, "closed"
  end

  local len = #str
  if len == 0 then
    -- Existing behaviour: zero-length write is a cheap no-op.
    return 0, nil
  end

  return self._ops.write(self._fd, str, len)
end

--- Seek within the file descriptor.
---
--- whence: "set" | "cur" | "end"
---@param whence '"set"'|'"cur"'|'"end"'
---@param off integer
---@return integer|nil pos, string|nil err
function FdBackend:seek(whence, off)
  if not self._fd then
    return nil, "closed"
  end
  return self._ops.seek(self._fd, whence, off)
end

--- Register for readability events on this fd.
---@param task Task
---@return WaitToken
function FdBackend:on_readable(task)
  return poller.get():wait(assert(self._fd, "closed fd"), "rd", task)
end

--- Register for writability events on this fd.
---@param task Task
---@return WaitToken
function FdBackend:on_writable(task)
  return poller.get():wait(assert(self._fd, "closed fd"), "wr", task)
end

--- Close the backend and underlying fd.
---
--- Returns:
---   ok  : true on success, false on failure
---   err : error string or nil
---
---@return boolean ok, string|nil err
function FdBackend:close()
  if self._fd == nil then
    return true, nil
  end

  local fd = self._fd
  self._fd = nil

  -- Matches old behaviour: fd is considered closed from the Lua side
  -- even if close() reports an error.
  return self._ops.close(fd)
end

----------------------------------------------------------------------
-- Backend builder
----------------------------------------------------------------------

--- Build a concrete fd backend module from low-level ops.
---
--- ops must provide:
---   set_nonblock(fd) -> ok, err|nil, errno|nil
---   read(fd, max)    -> s|nil, err|nil
---   write(fd, str, len) -> n|nil, err|nil
---   seek(fd, whence, off) -> pos|nil, err|nil
---   close(fd)        -> ok, err|nil
---
--- ops.is_supported() -> boolean (optional)
---
---@param ops table
---@return table backend_module  -- { new = fn, is_supported = fn }
local function build_backend(ops)
  local required = { "set_nonblock", "read", "write", "seek", "close" }
  for _, k in ipairs(required) do
    assert(type(ops[k]) == "function",
      "fd_backend ops." .. k .. " must be a function")
  end

  local function new(fd, opts)
    opts = opts or {}

    if fd ~= nil then
      local ok, err = ops.set_nonblock(fd)
      if not ok then
        error("fd_backend: set_nonblock(" .. tostring(fd) .. ") failed: "
          .. tostring(err))
      end
    end

    local self = {
      _fd      = fd,
      _ops     = ops,
      filename = opts.filename,
    }
    return setmetatable(self, FdBackend)
  end

  local function is_supported()
    if type(ops.is_supported) == "function" then
      return not not ops.is_supported()
    end
    return true
  end

  return {
    new          = new,
    is_supported = is_supported,
  }
end

return {
  build_backend = build_backend,
}

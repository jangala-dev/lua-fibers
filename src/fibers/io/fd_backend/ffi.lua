-- fibers/io/fd_backend/ffi.lua
--
-- FFI-based FD backend (no luaposix / syscall dependency).
-- Intended to be selected via fibers.io.fd_backend.

---@module 'fibers.io.fd_backend.ffi'

local poller  = require 'fibers.io.poller'
local ffi_c   = require 'fibers.utils.ffi_compat'

if not ffi_c.is_supported() then
  return { is_supported = function() return false end }
end

local ffi     = ffi_c.ffi
local C       = ffi_c.C
local toint   = ffi_c.tonumber
local get_errno = ffi_c.errno

local ok_bit, bit_mod = pcall(function()
  return rawget(_G, "bit") or require 'bit32'
end)
if not ok_bit or not bit_mod then
  return { is_supported = function() return false end }
end
local bit = bit_mod

ffi.cdef[[
  typedef long ssize_t;
  typedef long off_t;

  ssize_t read(int fd, void *buf, size_t count);
  ssize_t write(int fd, const void *buf, size_t count);
  off_t   lseek(int fd, off_t offset, int whence);
  int     close(int fd);
  int     fcntl(int fd, int cmd, ...);
  char   *strerror(int errnum);
]]

-- POSIX fcntl command numbers are stable (3/4) on Linux.
local F_GETFL    = 3
local F_SETFL    = 4

-- Default Linux O_NONBLOCK
local O_NONBLOCK = 0x00000800

-- Errno values: EAGAIN/EWOULDBLOCK are both 11 on Linux.
local EAGAIN      = 11
local EWOULDBLOCK = 11

local function strerror(e)
  local s = C.strerror(e)
  if s == nil then return "errno " .. tostring(e) end
  return ffi.string(s)
end

----------------------------------------------------------------------
-- fcntl helpers (casted to avoid varargs issues)
----------------------------------------------------------------------

local getfl_fp = ffi.cast("int (*)(int, int)",       C.fcntl)
local setfl_fp = ffi.cast("int (*)(int, int, int)",  C.fcntl)

local function set_nonblock(fd)
  local before = getfl_fp(fd, F_GETFL)
  local before_l = toint(before)
  if before_l < 0 then
    local e = get_errno()
    return false, ("F_GETFL failed: %s"):format(strerror(e)), e
  end

  local new_flags = bit.bor(before_l, O_NONBLOCK)
  local rc = setfl_fp(fd, F_SETFL, new_flags)
  local rc_l = toint(rc)
  if rc_l < 0 then
    local e = get_errno()
    return false, ("F_SETFL failed: %s"):format(strerror(e)), e
  end

  -- Sanity check: did the kernel actually set O_NONBLOCK?
  local after = getfl_fp(fd, F_GETFL)
  local after_l = toint(after)
  if after_l < 0 then
    local e = get_errno()
    return false, ("F_GETFL (post) failed: %s"):format(strerror(e)), e
  end

  if bit.band(after_l, O_NONBLOCK) == 0 then
    return false,
      ("set_nonblock: O_NONBLOCK not set after F_SETFL; before=0x%x after=0x%x")
        :format(before_l, after_l),
      nil
  end

  return true, nil, nil
end

----------------------------------------------------------------------
-- FdBackend implementation
----------------------------------------------------------------------

---@class FdBackend : StreamBackend
---@field filename string|nil

---@param fd integer|nil
---@param opts? { filename?: string }
---@return FdBackend
local function new(fd, opts)
  opts = opts or {}

  if fd ~= nil then
    local ok, err = set_nonblock(fd)
    if not ok then
      error("fd_backend.ffi: set_nonblock(" .. tostring(fd) .. ") failed: "
        .. tostring(err))
    end
  end

  ---@class FdBackend
  local B = {
    filename = opts.filename,
  }

  function B:kind()
    return "fd"
  end

  function B:fileno()
    return fd
  end

  --------------------------------------------------------------------
  -- String-oriented I/O
  --------------------------------------------------------------------

  ---@param max? integer
  ---@return string|nil s, string|nil err
  function B:read_string(max)
    if not fd then
      return nil, "closed"
    end

    max = max or 4096
    if max <= 0 then
      return "", nil
    end

    local buf = ffi.new("char[?]", max)
    local n   = C.read(fd, buf, max)
    local n_l = toint(n)

    if n_l < 0 then
      local e = get_errno()
      if e == EAGAIN or e == EWOULDBLOCK then
        return nil, nil   -- would block
      end
      return nil, strerror(e)
    end

    if n_l == 0 then
      return "", nil      -- EOF
    end

    if n_l > max then
      return nil, "read returned " .. tostring(n_l) .. " bytes (max " .. tostring(max) .. ")"
    end

    return ffi.string(buf, n_l), nil
  end

  ---@param str string
  ---@return integer|nil n, string|nil err
  function B:write_string(str)
    if not fd then
      return nil, "closed"
    end

    local len = #str
    if len == 0 then
      return 0, nil
    end

    local buf = ffi.new("char[?]", len)
    ffi.copy(buf, str, len)

    local n   = C.write(fd, buf, len)
    local n_l = toint(n)

    if n_l < 0 then
      local e = get_errno()
      if e == EAGAIN or e == EWOULDBLOCK then
        return nil, nil   -- would block
      end
      return nil, strerror(e)
    end

    return n_l, nil
  end

  --------------------------------------------------------------------
  -- Seek
  --------------------------------------------------------------------

  local SEEK = { set = 0, cur = 1, ["end"] = 2 }

  ---@param whence '"set"'|'"cur"'|'"end"'
  ---@param off integer
  ---@return integer|nil pos, string|nil err
  function B:seek(whence, off)
    if not fd then
      return nil, "closed"
    end

    local w = SEEK[whence]
    if not w then
      return nil, "bad whence: " .. tostring(whence)
    end

    local res   = C.lseek(fd, off, w)
    local res_l = toint(res)
    if res_l < 0 then
      return nil, strerror(get_errno())
    end

    return res_l, nil
  end

  --------------------------------------------------------------------
  -- Readiness registration
  --------------------------------------------------------------------

  function B:on_readable(task)
    return poller.get():wait(assert(fd, "closed fd"), "rd", task)
  end

  function B:on_writable(task)
    return poller.get():wait(assert(fd, "closed fd"), "wr", task)
  end

  --------------------------------------------------------------------
  -- Lifecycle
  --------------------------------------------------------------------

  ---@return boolean ok, string|nil err
  function B:close()
    if fd == nil then
      return true, nil
    end

    local rc = C.close(fd)
    fd = nil
    if toint(rc) ~= 0 then
      return false, strerror(get_errno())
    end
    return true, nil
  end

  return B
end

local function is_supported()
  -- We already gated on ffi_compat + bit; this backend is intended for Linux.
  return true
end

return {
  new          = new,
  is_supported = is_supported,
}

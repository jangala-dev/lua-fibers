-- fibers/io/fd_backend/ffi.lua
--
-- FFI-based FD backend (no luaposix / syscall dependency).
-- Intended to be selected via fibers.io.fd_backend.
--
---@module 'fibers.io.fd_backend.ffi'

local core   = require 'fibers.io.fd_backend.core'
local ffi_c  = require 'fibers.utils.ffi_compat'

if not ffi_c.is_supported() then
  return { is_supported = function() return false end }
end

local ffi       = ffi_c.ffi
local C         = ffi_c.C
local toint     = ffi_c.tonumber
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

-- POSIX fcntl command numbers on Linux.
local F_GETFL    = 3
local F_SETFL    = 4

-- Linux O_NONBLOCK (matches luaposix O_NONBLOCK on this platform).
local O_NONBLOCK = 0x00000800

-- Errno values: EAGAIN/EWOULDBLOCK are both 11 on Linux.
local EAGAIN      = 11
local EWOULDBLOCK = 11

local function strerror(e)
  local s = C.strerror(e)
  if s == nil then
    return "errno " .. tostring(e)
  end
  return ffi.string(s)
end

----------------------------------------------------------------------
-- fcntl helpers (casted to avoid varargs issues)
----------------------------------------------------------------------

local getfl_fp = ffi.cast("int (*)(int, int)",      C.fcntl)
local setfl_fp = ffi.cast("int (*)(int, int, int)", C.fcntl)

local function set_nonblock(fd)
  local before   = toint(getfl_fp(fd, F_GETFL))
  if before < 0 then
    local e = get_errno()
    return false, ("F_GETFL failed: %s"):format(strerror(e)), e
  end

  local new_flags = bit.bor(before, O_NONBLOCK)
  local rc        = toint(setfl_fp(fd, F_SETFL, new_flags))
  if rc < 0 then
    local e = get_errno()
    return false, ("F_SETFL failed: %s"):format(strerror(e)), e
  end

  -- Sanity check.
  local after = toint(getfl_fp(fd, F_GETFL))
  if after < 0 then
    local e = get_errno()
    return false, ("F_GETFL (post) failed: %s"):format(strerror(e)), e
  end

  if bit.band(after, O_NONBLOCK) == 0 then
    return false,
      ("set_nonblock: O_NONBLOCK not set after F_SETFL; before=0x%x after=0x%x")
        :format(before, after),
      nil
  end

  return true, nil, nil
end

----------------------------------------------------------------------
-- Low-level ops implementing the core contract
----------------------------------------------------------------------

local SEEK = { set = 0, cur = 1, ["end"] = 2 }

local function read_fd(fd, max)
  -- max > 0 and fd non-nil guaranteed by core.
  local buf = ffi.new("char[?]", max)
  local n   = toint(C.read(fd, buf, max))

  if n < 0 then
    local e = get_errno()
    if e == EAGAIN or e == EWOULDBLOCK then
      return nil, nil    -- would block
    end
    return nil, strerror(e)
  end

  if n == 0 then
    return "", nil       -- EOF
  end

  if n > max then
    return nil, "read returned " .. tostring(n) .. " bytes (max " .. tostring(max) .. ")"
  end

  return ffi.string(buf, n), nil
end

local function write_fd(fd, str, len)
  -- len > 0 and fd non-nil guaranteed by core.
  local buf = ffi.new("char[?]", len)
  ffi.copy(buf, str, len)

  local n = toint(C.write(fd, buf, len))
  if n < 0 then
    local e = get_errno()
    if e == EAGAIN or e == EWOULDBLOCK then
      return nil, nil    -- would block
    end
    return nil, strerror(e)
  end

  return n, nil
end

local function seek_fd(fd, whence, off)
  local w = SEEK[whence]
  if not w then
    return nil, "bad whence: " .. tostring(whence)
  end

  local res = toint(C.lseek(fd, off, w))
  if res < 0 then
    return nil, strerror(get_errno())
  end

  return res, nil
end

local function close_fd(fd)
  local rc = toint(C.close(fd))
  if rc ~= 0 then
    return false, strerror(get_errno())
  end
  return true, nil
end

local ops = {
  set_nonblock = set_nonblock,
  read         = read_fd,
  write        = write_fd,
  seek         = seek_fd,
  close        = close_fd,
  is_supported = function() return true end,
}

return core.build_backend(ops)

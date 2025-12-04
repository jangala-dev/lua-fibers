-- fibers/io/fd_backend/posix.lua
--
-- luaposix-based FD backend for files/sockets.
-- Intended as a fallback where FFI is unavailable or undesired.
--
---@module 'fibers.io.fd_backend.posix'

local core = require 'fibers.io.fd_backend.core'

local ok_unistd, unistd = pcall(require, 'posix.unistd')
local ok_fcntl,  fcntl  = pcall(require, 'posix.fcntl')
local ok_errno,  errno  = pcall(require, 'posix.errno')

if not (ok_unistd and ok_fcntl and ok_errno) then
  return {
    is_supported = function() return false end,
  }
end

local bit = rawget(_G, "bit") or require 'bit32'

local EAGAIN      = errno.EAGAIN
local EWOULDBLOCK = errno.EWOULDBLOCK or errno.EAGAIN

local SEEK_SET = fcntl.SEEK_SET or 0
local SEEK_CUR = fcntl.SEEK_CUR or 1
local SEEK_END = fcntl.SEEK_END or 2

----------------------------------------------------------------------
-- Non-blocking helper
----------------------------------------------------------------------

local function set_nonblock(fd)
  local flags, err, en = fcntl.fcntl(fd, fcntl.F_GETFL)
  if flags == nil then
    return nil, err or ("fcntl(F_GETFL) errno " .. tostring(en)), en
  end

  local newflags          = bit.bor(flags, fcntl.O_NONBLOCK)
  local ok2, err2, en2    = fcntl.fcntl(fd, fcntl.F_SETFL, newflags)
  if ok2 == nil then
    return nil, err2 or ("fcntl(F_SETFL) errno " .. tostring(en2)), en2
  end

  return true, nil, nil
end

----------------------------------------------------------------------
-- Low-level ops implementing the core contract
----------------------------------------------------------------------

local SEEK = {
  set   = SEEK_SET,
  cur   = SEEK_CUR,
  ["end"] = SEEK_END,
}

local function read_fd(fd, max)
  -- max > 0 and fd non-nil guaranteed by core.
  local s, err, en = unistd.read(fd, max)
  if s == nil then
    if en == EAGAIN or en == EWOULDBLOCK then
      return nil, nil      -- would block
    end
    return nil, err or ("errno " .. tostring(en))
  end

  -- s may be "" at EOF.
  return s, nil
end

local function write_fd(fd, str, _len)
  local n, err, en = unistd.write(fd, str)
  if n == nil then
    if en == EAGAIN or en == EWOULDBLOCK then
      return nil, nil      -- would block
    end
    return nil, err or ("errno " .. tostring(en))
  end

  return n, nil
end

local function seek_fd(fd, whence, off)
  local w = SEEK[whence]
  if not w then
    return nil, "bad whence: " .. tostring(whence)
  end

  local pos, err, en = unistd.lseek(fd, off, w)
  if pos == nil then
    return nil, err or ("errno " .. tostring(en))
  end
  return pos, nil
end

local function close_fd(fd)
  local ok, err, en = unistd.close(fd)
  if ok == nil or ok == false then
    return false, err or ("errno " .. tostring(en))
  end
  return true, nil
end

local ops = {
  set_nonblock = set_nonblock,
  read         = read_fd,
  write        = write_fd,
  seek         = seek_fd,
  close        = close_fd,
}

local backend = core.build_backend(ops)

-- Preserve explicit is_supported for symmetry with ffi backend.
backend.is_supported = function()
  return true
end

return backend

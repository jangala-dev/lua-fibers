-- fibers/io/fd_backend/posix.lua
--
-- luaposix-based FD backend for files/sockets.
--
-- Backend contract towards fibers.io.stream:
--   * kind()              -> "fd"
--   * fileno()            -> fd
--   * read_string(max)    -> str|nil, err|nil
--   * write_string(str)   -> n|nil, err|nil
--   * on_readable(task)   -> token{ unlink = fn }
--   * on_writable(task)   -> token{ unlink = fn }
--   * close()             -> ok, err|nil
--   * seek(whence, off)   -> pos|nil, err|nil

---@module 'fibers.io.fd_backend.posix'

local poller = require 'fibers.io.poller'

local ok_unistd, unistd = pcall(require, 'posix.unistd')
local ok_fcntl,  fcntl  = pcall(require, 'posix.fcntl')
local ok_errno,  errno  = pcall(require, 'posix.errno')

if not (ok_unistd and ok_fcntl and ok_errno) then
  return {
    is_supported = function() return false end,
  }
end

local bit = rawget(_G, "bit") or require 'bit32'

local EAGAIN     = errno.EAGAIN
local EWOULDBLOCK = errno.EWOULDBLOCK or errno.EAGAIN

local SEEK_SET   = fcntl.SEEK_SET or 0
local SEEK_CUR   = fcntl.SEEK_CUR or 1
local SEEK_END   = fcntl.SEEK_END or 2

local function set_nonblock(fd)
  local flags, err, en = fcntl.fcntl(fd, fcntl.F_GETFL)
  if flags == nil then
    return nil, err or ("fcntl(F_GETFL) errno " .. tostring(en)), en
  end

  local newflags = bit.bor(flags, fcntl.O_NONBLOCK)
  local ok, err2, en2 = fcntl.fcntl(fd, fcntl.F_SETFL, newflags)
  if ok == nil then
    return nil, err2 or ("fcntl(F_SETFL) errno " .. tostring(en2)), en2
  end

  return true, nil, nil
end

--- FD-backed stream backend for use with fibers.io.stream.
---@class FdBackend : StreamBackend
---@field filename string|nil

--- Create a new FD backend instance.
---@param fd integer|nil
---@param opts? { filename?: string }
---@return FdBackend
local function new(fd, opts)
  opts = opts or {}

  if fd ~= nil then
    local ok, err = set_nonblock(fd)
    if not ok then
      error("set_nonblock failed: " .. tostring(err))
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

  function B:read_string(max)
    if not fd then
      return nil, "closed"
    end

    max = max or 4096
    if max <= 0 then
      return "", nil
    end

    local s, err, en = unistd.read(fd, max)
    if s == nil then
      if en == EAGAIN or en == EWOULDBLOCK then
        -- Would block.
        return nil, nil
      end
      return nil, err or ("errno " .. tostring(en))
    end

    -- s may be "" at EOF; that is fine.
    return s, nil
  end

  function B:write_string(str)
    if not fd then
      return nil, "closed"
    end

    local n, err, en = unistd.write(fd, str)
    if n == nil then
      if en == EAGAIN or en == EWOULDBLOCK then
        -- Would block.
        return nil, nil
      end
      return nil, err or ("errno " .. tostring(en))
    end

    return n, nil
  end

  --------------------------------------------------------------------
  -- Seek (used by Stream:seek)
  --------------------------------------------------------------------

  local SEEK = {
    set   = SEEK_SET,
    cur   = SEEK_CUR,
    ["end"] = SEEK_END,
  }

  function B:seek(whence, off)
    if not fd then
      return nil, "closed"
    end

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

  --------------------------------------------------------------------
  -- Readiness registration (for waitable/poller)
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

  function B:close()
    if fd == nil then
      return true, nil
    end

    local ok, err, en = unistd.close(fd)
    fd = nil
    if ok == nil or ok == false then
      return false, err or ("errno " .. tostring(en))
    end
    return true, nil
  end

  return B
end

local function is_supported()
  return true
end

return {
  new          = new,
  is_supported = is_supported,
}

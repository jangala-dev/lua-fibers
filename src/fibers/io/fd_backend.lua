-- fibers/io/fd_backend.lua
--
-- FD-backed backend for files/sockets.
--
-- Backend contract towards fibers.io.stream:
--   * kind()              -> "fd"
--   * fileno()            -> fd
--   * read_string(max)    -> str|nil, err|nil
--        - str == nil  : would block
--        - str == ""   : EOF
--   * write_string(str)   -> n|nil, err|nil
--        - n == nil    : would block
--   * on_readable(task)   -> token{ unlink = fn }
--   * on_writable(task)   -> token{ unlink = fn }
--   * close()             -> ok, err|nil
--   * seek(whence, off)   -> pos|nil, err|nil
--        - whence: "set" | "cur" | "end"
---@module 'fibers.io.fd_backend'

local sc     = require 'fibers.utils.syscall'
local poller = require 'fibers.io.poller'

--- FD-backed stream backend for use with fibers.io.stream.
---@class FdBackend : StreamBackend
---@field filename string|nil

--- Create a new FD backend instance.
---@param fd integer|nil
---@param opts? { filename?: string }
---@return FdBackend
local function new(fd, opts)
  opts = opts or {}

  -- Ensure the descriptor is in non-blocking mode.
  if fd ~= nil then
    sc.set_nonblock(fd)
  end

  ---@class FdBackend
  local B = {
    filename = opts.filename,
  }

  --- Return backend kind identifier.
  ---@return '"fd"'
  function B:kind()
    return "fd"
  end

  --- Return underlying file descriptor number, or nil if closed.
  ---@return integer|nil
  function B:fileno()
    return fd
  end

  --------------------------------------------------------------------
  -- String-oriented I/O, for use by fibers.io.stream
  --------------------------------------------------------------------

  --- Read up to max bytes as a Lua string.
  ---
  --- Returns:
  ---   s       : string ("" at EOF) or nil
  ---   err     : string or nil
  ---
  --- Semantics:
  ---   * s == nil, err == nil      : would block
  ---   * s == nil, err ~= nil      : hard error
  ---   * s == ""                   : EOF
  ---   * s ~= ""                   : data
  ---@param max? integer
  ---@return string|nil s, string|nil err
  function B:read_string(max)
    if not fd then
      return nil, "closed"
    end

    max = max or 4096

    local s, err, errno = sc.read(fd, max)
    if s == nil then
      -- Would block.
      if errno == sc.EAGAIN or errno == sc.EWOULDBLOCK then
        return nil, nil
      end
      -- Hard error.
      return nil, err or ("errno " .. tostring(errno))
    end

    -- Success, including EOF when s == "".
    return s, nil
  end

  --- Write a Lua string.
  ---
  --- Returns:
  ---   n       : number of bytes written, or nil
  ---   err     : string or nil
  ---
  --- Semantics:
  ---   * n == nil, err == nil      : would block
  ---   * n == nil, err ~= nil      : hard error
  ---   * n >= 0                    : bytes written
  ---@param str string
  ---@return integer|nil n, string|nil err
  function B:write_string(str)
    if not fd then
      return nil, "closed"
    end

    local n, err, errno = sc.write(fd, str)
    if n == nil then
      if errno == sc.EAGAIN or errno == sc.EWOULDBLOCK then
        -- Would block.
        return nil, nil
      end
      -- Hard error.
      return nil, err or ("errno " .. tostring(errno))
    end

    return n, nil
  end

  --------------------------------------------------------------------
  -- Seek (used by Stream:seek)
  --------------------------------------------------------------------

  local SEEK = {
    set   = sc.SEEK_SET,
    cur   = sc.SEEK_CUR,
    ["end"] = sc.SEEK_END,
  }

  --- Seek within the file descriptor.
  ---
  --- whence: "set" | "cur" | "end"
  --- off   : byte offset
  ---
  --- Returns:
  ---   pos   : new offset, or nil
  ---   err   : string or nil
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

    return sc.lseek(fd, off, w)
  end

  --------------------------------------------------------------------
  -- Readiness registration (for waitable/poller)
  --------------------------------------------------------------------

  --- Register for readability events on this fd.
  ---@param task Task
  ---@return WaitToken
  function B:on_readable(task)
    return poller.get():wait(assert(fd, "closed fd"), "rd", task)
  end

  --- Register for writability events on this fd.
  ---@param task Task
  ---@return WaitToken
  function B:on_writable(task)
    return poller.get():wait(assert(fd, "closed fd"), "wr", task)
  end

  --------------------------------------------------------------------
  -- Lifecycle
  --------------------------------------------------------------------

  --- Close the backend and underlying fd.
  ---@return boolean ok, string|nil err
  function B:close()
    if fd == nil then
      return true
    end

    local ok, err = sc.close(fd)
    fd = nil
    return ok, err
  end

  return B
end

return { new = new }

-- fibers/io/fd_backend/nixio.lua
--
-- nixio-based FD backend (no FFI / luaposix dependency).
-- Intended to be selected via fibers.io.fd_backend.
--
---@module 'fibers.io.fd_backend.nixio'

local core  = require 'fibers.io.fd_backend.core'
local nixio = require 'nixio'
local fs    = require 'nixio.fs'

local const = nixio.const or {}

local EAGAIN      = const.EAGAIN      or 11
local EWOULDBLOCK = const.EWOULDBLOCK or EAGAIN
local EINPROGRESS = const.EINPROGRESS or 115
local EALREADY    = const.EALREADY    or 114

-- Where available, reuse nixio’s numeric constants so callers see
-- sensible AF_* / SOCK_* values. Fall back to standard-ish defaults.
local AF_UNIX     = const.AF_UNIX     or 1
local AF_INET     = const.AF_INET
local AF_INET6    = const.AF_INET6
local SOCK_STREAM = const.SOCK_STREAM or 1
local SOCK_DGRAM  = const.SOCK_DGRAM  or 2

local function errno_msg(default, eno)
  if not eno or eno == 0 then
    return default
  end
  local s = nixio.strerror(eno)
  if not s or s == "" then
    return default .. " (errno " .. tostring(eno) .. ")"
  end
  return s
end

----------------------------------------------------------------------
-- Core ops: set_nonblock / read / write / seek / close
----------------------------------------------------------------------

-- fd here is a nixio.File or nixio.Socket
local function set_nonblock(fd)
  if fd and fd.setblocking then
    local ok, eno = fd:setblocking(false)
    if ok ~= nil and ok ~= false then
      return true, nil, eno
    end
    eno = eno or nixio.errno()
    return false, errno_msg("setblocking(false) failed", eno), eno
  end
  -- If there is no setblocking, treat as already non-blocking.
  return true, nil, nil
end

local function read_fd(fd, max)
  if not fd then
    return nil, "closed"
  end

  max = max or const.buffersize or 8192
  if max <= 0 then
    return "", nil
  end

  -- nixio.File:read / Socket:read both follow the same style:
  --   data                      (success/EOF)
  --   nil, msg, errno           (error)
  local data, msg, eno = fd:read(max)

  if data ~= nil then
    -- data may be "" at EOF; that is acceptable to callers.
    return data, nil
  end

  eno = eno or nixio.errno()

  if eno == EAGAIN or eno == EWOULDBLOCK then
    -- Would block, signal “not ready yet”.
    return nil, nil
  end

  if not eno or eno == 0 then
    -- Treat as EOF.
    return "", nil
  end

  return nil, errno_msg(msg or "read failed", eno)
end

local function write_fd(fd, str, len)
  if not fd then
    return nil, "closed"
  end

  len = len or #str
  if len == 0 then
    return 0, nil
  end

  -- For files: File.write(buf, offset, length)
  -- For sockets: Socket.send / write(buf, offset, length) – same shape.
  local n, msg, eno = fd:write(str, 0, len)

  if n ~= nil then
    return n, nil
  end

  eno = eno or nixio.errno()

  if eno == EAGAIN or eno == EWOULDBLOCK then
    -- Would block.
    return nil, nil
  end

  return nil, errno_msg(msg or "write failed", eno)
end

local SEEK_MAP = {
  set   = "set",
  cur   = "cur",
  ["end"] = "end",
}

local function seek_fd(fd, whence, off)
  if not fd then
    return nil, "closed"
  end

  whence = SEEK_MAP[whence] or whence or "cur"
  off    = off or 0

  if not fd.seek then
    return nil, "seek not supported on this descriptor"
  end

  local pos, msg, eno = fd:seek(off, whence)
  if pos == nil then
    eno = eno or nixio.errno()
    return nil, errno_msg(msg or "seek failed", eno)
  end
  return pos, nil
end

local function close_fd(fd)
  if not fd then
    return true, nil
  end

  local ok, msg, eno = fd:close()
  if ok == nil or ok == false then
    eno = eno or nixio.errno()
    return false, errno_msg(msg or "close failed", eno)
  end
  return true, nil
end

----------------------------------------------------------------------
-- File-level helpers: open_file / pipe / mktemp / fsync / rename / unlink
----------------------------------------------------------------------

-- For this backend we rely on nixio.open’s mode strings.
local function open_file(path, mode, perms)
  mode = mode or "r"

  local f, eno = nixio.open(path, mode, perms)
  if not f then
    return nil, errno_msg("open failed", eno)
  end
  return f, nil
end

local function pipe_fds()
  local r, w, eno = nixio.pipe()
  if not r then
    return nil, nil, errno_msg("pipe failed", eno)
  end
  return r, w, nil
end

local function mktemp(prefix, perms)
  -- Very simple mktemp: we try a few names and rely on low collision
  -- probability. This mirrors the earlier “simple” backend you tested.
  local start = math.random(1e7)
  local last_err

  for i = start, start + 10 do
    local tmpnam = prefix .. "." .. i
    local f, eno = nixio.open(tmpnam, "w+", perms)
    if f then
      return f, tmpnam
    end
    last_err = errno_msg("mktemp open failed", eno)
  end

  return nil, last_err or "mktemp: failed to create temporary file"
end

local function fsync_fd(fd)
  if not fd or not fd.sync then
    return true, nil
  end
  local ok, msg, eno = fd:sync(false)
  if ok == nil or ok == false then
    eno = eno or nixio.errno()
    return false, errno_msg(msg or "fsync failed", eno)
  end
  return true, nil
end

local function rename_file(oldpath, newpath)
  local ok, msg, eno = fs.rename(oldpath, newpath)
  if ok == nil or ok == false then
    return false, errno_msg(msg or "rename failed", eno)
  end
  return true, nil
end

local function unlink_file(path)
  local ok, msg, eno = fs.unlink(path)
  if ok == nil or ok == false then
    return false, errno_msg(msg or "unlink failed", eno)
  end
  return true, nil
end

-- For this backend, integer open flags are not used; when decode_access
-- is called we can conservatively assume read/write.
local function decode_access(_)
  return true, true
end

local function ignore_sigpipe()
  -- Best-effort ignore of SIGPIPE.
  if nixio.signal and nixio.SIGPIPE then
    local ok, eno = nixio.signal(nixio.SIGPIPE, "ign")
    if ok == nil or ok == false then
      return false, errno_msg("signal(SIGPIPE) failed", eno)
    end
  end
  return true, nil
end

----------------------------------------------------------------------
-- Socket helpers
----------------------------------------------------------------------

local function domain_to_str(domain)
  if domain == AF_UNIX then
    return "unix"
  end
  if AF_INET and domain == AF_INET then
    return "inet"
  end
  if AF_INET6 and domain == AF_INET6 then
    return "inet6"
  end
  error("fd_backend.nixio: unsupported address family: " .. tostring(domain))
end

local function stype_to_str(stype)
  if stype == SOCK_STREAM then
    return "stream"
  end
  if SOCK_DGRAM and stype == SOCK_DGRAM then
    return "dgram"
  end
  error("fd_backend.nixio: unsupported socket type: " .. tostring(stype))
end

--- socket(domain, stype, protocol) -> fd|nil, err|nil, eno|nil
local function socket_fd(domain, stype, _)
  local d = domain_to_str(domain)
  local t = stype_to_str(stype)

  local s, eno = nixio.socket(d, t)
  if not s then
    return nil, errno_msg("socket failed", eno), eno
  end
  -- Returned “fd” is a nixio.Socket object.
  return s, nil, nil
end

--- bind(fd, sa) where fd is nixio.Socket; sa is e.g. UNIX path string.
local function bind_fd(fd, sa)
  if not fd then
    return false, "closed socket", nil
  end

  local ok, msg, eno

  if type(sa) == "string" then
    -- For AF_UNIX, host is path, port is ignored. We pass 0 as a dummy.
    ok, msg, eno = fd:bind(sa, 0)
  else
    return false, "unsupported sockaddr representation", nil
  end

  if ok == nil or ok == false then
    eno = eno or nixio.errno()
    return false, errno_msg(msg or "bind failed", eno), eno
  end

  return true, nil, nil
end

local function listen_fd(fd)
  if not fd then
    return false, "closed socket", nil
  end

  local backlog = const.SOMAXCONN or 128
  local ok, msg, eno = fd:listen(backlog)
  if ok == nil or ok == false then
    eno = eno or nixio.errno()
    return false, errno_msg(msg or "listen failed", eno), eno
  end
  return true, nil, nil
end

--- accept(fd) -> newfd|nil, err|nil, again:boolean
local function accept_fd(fd)
  if not fd then
    return nil, "closed socket", false
  end

  -- nixio.Socket.accept() -> newsock, host, port | nil, msg, errno
  local newsock, _, _, msg, eno = fd:accept()
  if newsock then
    return newsock, nil, false
  end

  eno = eno or nixio.errno()
  if eno == EAGAIN or eno == EWOULDBLOCK then
    return nil, nil, true
  end

  return nil, errno_msg(msg or "accept failed", eno), false
end

--- connect_start(fd, sa) -> ok|nil, err|nil, inprogress:boolean
local function connect_start_fd(fd, sa)
  if not fd then
    return nil, "closed socket", false
  end

  local ok, msg, eno

  if type(sa) == "string" then
    -- For AF_UNIX, host is path, port is ignored.
    ok, msg, eno = fd:connect(sa, 0)
  else
    return nil, "unsupported sockaddr representation", false
  end

  if ok then
    return true, nil, false
  end

  eno = eno or nixio.errno()
  if eno == EINPROGRESS or eno == EALREADY or eno == EAGAIN then
    -- Non-blocking connect in progress.
    return nil, nil, true
  end

  return nil, errno_msg(msg or "connect failed", eno), false
end

--- connect_finish(fd) -> ok:boolean, err|nil
local function connect_finish_fd(fd)
  if not fd then
    return false, "closed socket"
  end

  if not fd.getopt then
    -- Fallback: if we cannot inspect SO_ERROR, assume success.
    return true, nil
  end

  local soerr, msg, eno = fd:getopt("socket", "error")
  if soerr == nil then
    eno = eno or nixio.errno()
    return false, errno_msg(msg or "getsockopt(SO_ERROR) failed", eno)
  end

  if soerr == 0 then
    return true, nil
  end

  return false, errno_msg("connect error", soerr)
end

----------------------------------------------------------------------
-- Capability probe
----------------------------------------------------------------------

local function is_supported()
  -- If this module loaded, nixio was already required successfully.
  return true
end

----------------------------------------------------------------------
-- Assemble ops and build backend
----------------------------------------------------------------------

local ops = {
  -- Core file/socket descriptor ops
  set_nonblock   = set_nonblock,
  read           = read_fd,
  write          = write_fd,
  seek           = seek_fd,
  close          = close_fd,

  -- File-level helpers
  open_file      = open_file,
  pipe           = pipe_fds,
  mktemp         = mktemp,
  fsync          = fsync_fd,
  rename         = rename_file,
  unlink         = unlink_file,
  decode_access  = decode_access,
  ignore_sigpipe = ignore_sigpipe,

  -- Socket-level helpers
  socket         = socket_fd,
  bind           = bind_fd,
  listen         = listen_fd,
  accept         = accept_fd,
  connect_start  = connect_start_fd,
  connect_finish = connect_finish_fd,

  -- Metadata for callers (fibers.io.socket re-exports these)
  modes          = {},     -- not used for nixio; kept for compatibility
  permissions    = {},

  AF_UNIX        = AF_UNIX,
  SOCK_STREAM    = SOCK_STREAM,

  is_supported   = is_supported,
}

return core.build_backend(ops)

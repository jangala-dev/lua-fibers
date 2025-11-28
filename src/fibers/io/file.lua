-- fibers/io/file.lua
--
-- File-backed streams on top of fd_backend + stream.
--
-- Exposes:
--   fdopen(fd[, flags[, filename]]) -> Stream
--   open(filename[, mode[, perms]]) -> Stream | nil, err
--   pipe()                          -> read_stream, write_stream
--   mktemp(prefix[, perms])         -> fd, tmpname
--   tmpfile([perms[, tmpdir]])      -> Stream (auto-unlink on close)
--   init_nonblocking(fd)            -> sets fd non-blocking (compat)
---@module 'fibers.io.file'

local sc      = require 'fibers.utils.syscall'
local stream  = require 'fibers.io.stream'
local fd_back = require 'fibers.io.fd_backend'

local bit = rawget(_G, "bit") or require 'bit32'

-- Ignore SIGPIPE so write() failures are reported via errno.
sc.signal(sc.SIGPIPE, sc.SIG_IGN)

----------------------------------------------------------------------
-- Mode and permission tables
----------------------------------------------------------------------

---@type table<string, integer>
local modes = {
  r   = sc.O_RDONLY,
  w   = bit.bor(sc.O_WRONLY, sc.O_CREAT, sc.O_TRUNC),
  a   = bit.bor(sc.O_WRONLY, sc.O_CREAT, sc.O_APPEND),
  ["r+"] = sc.O_RDWR,
  ["w+"] = bit.bor(sc.O_RDWR, sc.O_CREAT, sc.O_TRUNC),
  ["a+"] = bit.bor(sc.O_RDWR, sc.O_CREAT, sc.O_APPEND),
}

do
  local binary_modes = {}
  for k, v in pairs(modes) do
    binary_modes[k .. "b"] = v
  end
  for k, v in pairs(binary_modes) do
    modes[k] = v
  end
end

---@type table<string, integer>
local permissions = {}
permissions["rw-r--r--"] = bit.bor(sc.S_IRUSR, sc.S_IWUSR, sc.S_IRGRP, sc.S_IROTH)
permissions["rw-rw-rw-"] = bit.bor(permissions["rw-r--r--"], sc.S_IWGRP, sc.S_IWOTH)

----------------------------------------------------------------------
-- Internal: wrap fd as a Stream
----------------------------------------------------------------------

--- Wrap an fd in a Stream using fd_backend.
---@param fd integer
---@param flags? integer
---@param filename? string
---@return Stream
local function fdopen(fd, flags, filename)
  -- If flags are not supplied, query them.
  if flags == nil then
    flags = assert(sc.fcntl(fd, sc.F_GETFL))
  else
    -- Historically needed for some 32-bit environments.
    if sc.O_LARGEFILE then
      flags = bit.bor(flags, sc.O_LARGEFILE)
    end
  end

  -- Determine readability / writability from flags.
  local readable, writable = false, false
  local mode = bit.band(flags, sc.O_ACCMODE)
  if mode == sc.O_RDONLY or mode == sc.O_RDWR then
    readable = true
  end
  if mode == sc.O_WRONLY or mode == sc.O_RDWR then
    writable = true
  end

  local stat = sc.fstat(fd)
  local blksize = stat and stat.st_blksize or nil

  local io = fd_back.new(fd, { filename = filename })

  return stream.open(io, readable, writable, blksize)
end

----------------------------------------------------------------------
-- Open by filename
----------------------------------------------------------------------

--- Open a file by name as a Stream.
---@param filename string
---@param mode? string
---@param perms? integer|string
---@return Stream|nil f, string|nil err
local function open_file(filename, mode, perms)
  mode = mode or "r"
  local flags = modes[mode]
  if not flags then
    return nil, "invalid mode: " .. tostring(mode)
  end

  -- Default permissions; umask still applies.
  if perms == nil then
    perms = permissions["rw-rw-rw-"]
  else
    perms = permissions[perms] or perms
  end

  local fd, err = sc.open(filename, flags, perms)
  if not fd then
    return nil, err
  end

  return fdopen(fd, flags, filename)
end

----------------------------------------------------------------------
-- Pipes
----------------------------------------------------------------------

--- Create a unidirectional pipe as two Streams (read, write).
---@return Stream r_stream, Stream w_stream
local function pipe()
  local rd, wr = assert(sc.pipe())
  local r_stream = fdopen(rd, sc.O_RDONLY)
  local w_stream = fdopen(wr, sc.O_WRONLY)
  return r_stream, w_stream
end

----------------------------------------------------------------------
-- mktemp / tmpfile
----------------------------------------------------------------------

--- Create a temporary file with a unique name.
---@param prefix string
---@param perms? integer
---@return integer|nil fd, string tmpname_or_err
local function mktemp(prefix, perms)
  perms = perms or permissions["rw-r--r--"]

  -- Caller is responsible for seeding math.random appropriately.
  local start = math.random(1e7)
  local tmpnam, fd, err

  for i = start, start + 10 do
    tmpnam = prefix .. "." .. i
    fd, err = sc.open(tmpnam, bit.bor(sc.O_CREAT, sc.O_RDWR, sc.O_EXCL), perms)
    if fd then
      return fd, tmpnam
    end
  end

  -- Environmental failure: report as (nil, err) rather than raising.
  return nil, ("failed to create temporary file %s: %s"):format(
    tostring(tmpnam),
    tostring(err)
  )
end

--- Create a temporary file wrapped as a Stream, with unlink-on-close semantics.
---@param perms? integer
---@param tmpdir? string
---@return Stream|nil f, string|nil err
local function tmpfile(perms, tmpdir)
  perms  = perms or permissions["rw-r--r--"]
  tmpdir = tmpdir or os.getenv("TMPDIR") or "/tmp"
  ---@cast tmpdir string  -- narrow for LuaLS

  local fd, tmpnam_or_err = mktemp(tmpdir .. "/tmp", perms)
  if not fd then
    -- Propagate mktemp failure as (nil, err).
    return nil, tmpnam_or_err
  end

  ---@type Stream
  local f = fdopen(fd, sc.O_RDWR, tmpnam_or_err)

  -- We want unlink-on-close semantics by default, with a way to
  -- disable that via :rename().
  local io = f.io
  assert(io, "tmpfile backend missing")
  ---@cast io StreamBackend

  ---@type fun(self: StreamBackend): boolean, string|nil
  local old_close = io.close

  --- Rename the temporary file and disable unlink-on-close behaviour.
  ---@param newname string
  ---@return boolean|nil ok, string|nil err
  function f:rename(newname)
    -- Flush buffered data first (various stream flavours).
    if self.flush_output then
      self:flush_output()
    elseif self.flush then
      self:flush()
    end

    local real_fd = io.fileno and io:fileno() or fd
    if real_fd then
      sc.fsync(real_fd)
    end

    local fname = assert(io.filename, "tmpfile has no filename")
    local ok, err = sc.rename(fname, newname)
    if not ok then
      -- Environmental failure: return nil, err.
      return nil, ("failed to rename %s to %s: %s"):format(
        tostring(fname),
        tostring(newname),
        tostring(err)
      )
    end

    io.filename = newname
    -- Disable remove-on-close: restore original close.
    io.close = old_close
    return true
  end

  --- Close the fd and unlink the temporary file.
  ---@return boolean ok, string|nil err
  function io:close()
    -- First close the descriptor.
    local ok, err = old_close(self)
    if not ok then
      return ok, err
    end

    local fname = assert(self.filename, "tmpfile has no filename")
    -- Then unlink the temporary file. If this fails we report it, but
    -- do not raise.
    local ok2, err2 = sc.unlink(fname)
    if not ok2 then
      return false, ("failed to remove %s: %s"):format(
        tostring(fname),
        tostring(err2)
      )
    end

    return true, nil
  end

  return f
end

----------------------------------------------------------------------
-- Compatibility helper
----------------------------------------------------------------------

--- Put an fd into non-blocking mode.
---@param fd integer
---@return boolean ok, string|nil err
local function init_nonblocking(fd)
  return assert(sc.set_nonblock(fd))
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

return {
  fdopen           = fdopen,
  open             = open_file,
  pipe             = pipe,
  mktemp           = mktemp,
  tmpfile          = tmpfile,
  init_nonblocking = init_nonblocking,
  modes            = modes,
  permissions      = permissions,
}

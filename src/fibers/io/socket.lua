-- fibers/io/socket.lua
--
-- Socket helpers on top of fd_backend + stream.
--
-- Exposes:
--   socket(domain, stype, protocol?) -> Socket
--   listen_unix(path, opts?)         -> Socket (listening AF_UNIX)
--   connect_unix(path, stype?, proto?) -> Stream
--
-- Where Socket supports:
--   :listen_unix(path)
--   :accept_op()   -> Op (resolves to Stream | nil, err)
--   :accept()         -> Stream | nil, err
--   :connect_op(sa)-> Op (resolves to Stream | nil, err)
--   :connect(sa)      -> Stream | nil, err
--   :connect_unix(path) / :connect_unix_op(path)
--   :close()
---@module 'fibers.io.socket'

local sc         = require 'fibers.utils.syscall'
local wait       = require 'fibers.wait'
local poller_mod = require 'fibers.io.poller'
local fd_backend = require 'fibers.io.fd_backend'
local stream_mod = require 'fibers.io.stream'
local perform    = require 'fibers.performer'.perform

---@class Socket
---@field fd integer|nil
---@field listen_unix fun(self: Socket, path: string): (boolean|nil, string|nil)
---@field accept_op fun(self: Socket): Op
---@field accept fun(self: Socket): (Stream|nil, string|nil)
---@field connect_op fun(self: Socket, sa: any): Op
---@field connect fun(self: Socket, sa: any): (Stream|nil, string|nil)
---@field connect_unix_op fun(self: Socket, path: string): Op
---@field connect_unix fun(self: Socket, path: string): (Stream|nil, string|nil)
---@field close fun(self: Socket): (boolean, string|nil)
local Socket = {}
Socket.__index = Socket

-- Ignore SIGPIPE once; write errors will be reported via errno instead.
sc.signal(sc.SIGPIPE, sc.SIG_IGN)

--- Wrap a raw fd in a Socket.
---@param fd integer
---@return Socket
local function new_socket(fd)
  -- The fd itself is left for fd_backend.new to put into non-blocking mode
  -- and to register with the poller when used for I/O.
  return setmetatable({ fd = fd }, Socket)
end

--- Create a new non-blocking socket.
---@param domain integer
---@param stype integer
---@param protocol? integer
---@return Socket|nil s, any err
local function socket(domain, stype, protocol)
  local fd, err = sc.socket(domain, stype, protocol or 0)
  if not fd then
    return nil, err
  end
  -- We expect non-blocking behaviour; let fd_backend enforce this when
  -- the fd is wrapped. For defensive programming you can also call:
  --   sc.set_nonblock(fd)
  sc.set_nonblock(fd)
  return new_socket(fd)
end

----------------------------------------------------------------------
-- Helpers: wrap an fd into a Stream
----------------------------------------------------------------------

--- Wrap an fd as a full-duplex Stream.
---@param fd integer
---@param filename? string
---@return Stream
local function fd_to_stream(fd, filename)
  local stat = sc.fstat(fd)
  local blksize = stat and stat.st_blksize or nil

  local io = fd_backend.new(fd, { filename = filename })
  -- For sockets we assume readable + writable.
  return stream_mod.open(io, true, true, blksize)
end

----------------------------------------------------------------------
-- Listening and address helpers
----------------------------------------------------------------------

--- Listen on a UNIX-domain path using this Socket.
---@param path string
---@return boolean|nil ok, any err
function Socket:listen_unix(path)
  assert(self.fd, "socket is closed")

  local sa = sc.getsockname(self.fd)
  sa.path = path

  local ok, err = sc.bind(self.fd, sa)
  if not ok then
    -- Environmental failure: address in use, permissions, etc.
    return nil, ("bind failed: %s"):format(tostring(err))
  end

  ok, err = sc.listen(self.fd)
  if not ok then
    return nil, ("listen failed: %s"):format(tostring(err))
  end

  return true
end

----------------------------------------------------------------------
-- accept() as an Op
----------------------------------------------------------------------

--- Build an Op that accepts a connection and returns a Stream.
---@return Op
function Socket:accept_op()
  assert(self.fd, "socket is closed")

  local P  = poller_mod.get()
  local fd = self.fd

  local function step()
    local new_fd, err, errno = sc.accept(fd)
    if new_fd then
      -- Successful accept.
      return true, new_fd, nil
    end
    if errno == sc.EAGAIN or errno == sc.EWOULDBLOCK then
      -- Would block: wait for readability.
      return false
    end
    -- Hard error.
    return true, nil, err or ("errno " .. tostring(errno))
  end

  -- Only declare the parameter you actually use.
  local function register(task)
    -- wait.waitable will call this as register(task, suspension, leaf_wrap),
    -- but the extra arguments are harmlessly discarded by Lua.
    return P:wait(fd, "rd", task)
  end

  local function wrap(new_fd, err)
    if not new_fd then
      return nil, err
    end
    sc.set_nonblock(new_fd)
    return fd_to_stream(new_fd)
  end

  return wait.waitable(register, step, wrap)
end

--- Accept a connection synchronously into a Stream.
---@return Stream|nil client, any err
function Socket:accept()
  return perform(self:accept_op())
end

----------------------------------------------------------------------
-- connect() as an Op
----------------------------------------------------------------------

--- Build an Op that connects this Socket to a sockaddr.
---@param sa any
---@return Op
function Socket:connect_op(sa)
  assert(self.fd, "socket is closed")

  local P  = poller_mod.get()
  local fd = self.fd
  local state = "initial"

  local function step()
    if state == "initial" then
      local ok, err, errno = sc.connect(fd, sa)
      if ok then
        -- Immediate success.
        return true, true, nil
      end
      if errno == sc.EINPROGRESS then
        -- Standard non-blocking connect semantics: wait for writability.
        state = "waiting"
        return false
      end
      -- Hard failure.
      return true, false, err or ("errno " .. tostring(errno))
    elseif state == "waiting" then
      -- Connection completed or failed; check SO_ERROR.
      local soerr = sc.getsockopt(fd, sc.SOL_SOCKET, sc.SO_ERROR)
      if soerr == nil then
        return true, false, "getsockopt(SO_ERROR) failed"
      end
      if soerr == 0 then
        return true, true, nil
      else
        return true, false, "connect error errno " .. tostring(soerr)
      end
    else
      return true, false, "invalid connect state"
    end
  end

  -- Again, only the argument you use.
  local function register(task)
    return P:wait(fd, "wr", task)
  end

  local function wrap(ok, err)
    if not ok then
      return nil, err
    end
    local new_fd = fd
    self.fd = nil
    return fd_to_stream(new_fd)
  end

  return wait.waitable(register, step, wrap)
end

--- Connect synchronously and return a Stream.
---@param sa any
---@return Stream|nil stream, any err
function Socket:connect(sa)
  return perform(self:connect_op(sa))
end

----------------------------------------------------------------------
-- UNIX-domain convenience
----------------------------------------------------------------------

--- Build an Op that connects this socket to a UNIX-domain path.
---@param path string
---@return Op
function Socket:connect_unix_op(path)
  assert(self.fd, "socket is closed")

  local sa = sc.getsockname(self.fd)
  sa.path = path
  return self:connect_op(sa)
end

--- Connect synchronously to a UNIX-domain path.
---@param path string
---@return Stream|nil stream, any err
function Socket:connect_unix(path)
  return perform(self:connect_unix_op(path))
end

--- Listen on a UNIX-domain path and return a listening Socket.
---@param path string
---@param opts? { stype?: integer, protocol?: integer, ephemeral?: boolean }
---@return Socket|nil s, any err
local function listen_unix(path, opts)
  opts = opts or {}

  local s, err = socket(sc.AF_UNIX, opts.stype or sc.SOCK_STREAM, opts.protocol)
  if not s then
    return nil, err
  end

  local ok, lerr = s:listen_unix(path)
  if not ok then
    -- Clean up the socket on failure, then propagate the error.
    s:close()
    return nil, lerr
  end

  if opts.ephemeral then
    local parent_close = s.close
    ---@diagnostic disable-next-line: inject-field
    function s:close()
      local ok1, err1 = parent_close(self)

      local ok2, err2, errno2 = sc.unlink(path)
      -- Treat ENOENT as benign; other failures are reported.
      if not ok2 and errno2 ~= sc.ENOENT then
        return false, ("failed to remove %s: %s"):format(tostring(path), tostring(err2))
      end

      -- If the socket close was fine, report success overall.
      if ok1 == false then return false, err1 end
      return true, nil
    end
  end

  return s
end

--- Connect to a UNIX-domain socket path and return a Stream.
---@param path string
---@param stype? integer
---@param protocol? integer
---@return Stream|nil stream, any err
local function connect_unix(path, stype, protocol)
  local s, err = socket(sc.AF_UNIX, stype or sc.SOCK_STREAM, protocol)
  if not s then
    return nil, err
  end
  local stream, cerr = s:connect_unix(path)
  if not stream then
    return nil, cerr
  end
  return stream
end

----------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------

--- Close the underlying socket fd.
---@return boolean ok, any err
function Socket:close()
  if self.fd then
    sc.close(self.fd)
    self.fd = nil
  end
  return true
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

return {
  socket        = socket,
  listen_unix   = listen_unix,
  connect_unix  = connect_unix,
  Socket        = Socket,
}

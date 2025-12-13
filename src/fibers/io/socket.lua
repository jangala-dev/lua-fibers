-- fibers/io/socket.lua
--
-- Socket helpers on top of fd_backend + stream.
--
-- Exposes:
--   socket(domain, stype, protocol?) -> Socket
--   listen_unix(path, opts?)         -> Socket (listening AF_UNIX)
--   connect_unix(path, stype?, proto?) -> Stream
--
-- Socket (AF_UNIX focus) supports:
--   :listen_unix(path)
--   :accept_op()          -> Op (resolves to Stream|nil, err)
--   :accept()             -> Stream|nil, err
--   :connect_op(sa)       -> Op (sa currently a UNIX path string)
--   :connect(sa)
--   :connect_unix_op(path)
--   :connect_unix(path)
--   :close()
--
---@module 'fibers.io.socket'

local wait       = require 'fibers.wait'
local poller_mod = require 'fibers.io.poller'
local fd_backend = require 'fibers.io.fd_backend'
local stream_mod = require 'fibers.io.stream'
local perform    = require 'fibers.performer'.perform

---@class Socket
---@field fd integer|nil
local Socket = {}
Socket.__index = Socket

----------------------------------------------------------------------
-- Internal helpers
----------------------------------------------------------------------

--- Wrap an fd as a full-duplex Stream.
---@param fd integer
---@param filename? string
---@return Stream
local function fd_to_stream(fd, filename)
	local io = fd_backend.new(fd, { filename = filename })
	-- For sockets we assume readable + writable.
	return stream_mod.open(io, true, true)
end

--- Create a new non-blocking socket object from an fd.
---@param fd integer
---@return Socket
local function new_socket(fd)
	-- Ensure non-blocking behaviour.
	local ok, err = fd_backend.set_nonblock(fd)
	if not ok then
		fd_backend.close_fd(fd)
		error('set_nonblock(socket fd) failed: ' .. tostring(err))
	end
	return setmetatable({ fd = fd }, Socket)
end

--- Return underlying fd or error if closed.
---@return integer
function Socket:_fd()
	local fd = self.fd
	assert(fd, 'socket is closed')
	return fd
end

----------------------------------------------------------------------
-- Constructors
----------------------------------------------------------------------

--- Create a new non-blocking socket via the backend.
---@param domain integer
---@param stype integer
---@param protocol? integer
---@return Socket|nil s, any err
local function socket(domain, stype, protocol)
	local fd, err = fd_backend.socket(domain, stype, protocol or 0)
	if not fd then
		return nil, err
	end
	local ok, nerr = fd_backend.set_nonblock(fd)
	if not ok then
		fd_backend.close_fd(fd)
		return nil, nerr
	end
	return new_socket(fd)
end

----------------------------------------------------------------------
-- Listening and address helpers (UNIX domain)
----------------------------------------------------------------------

--- Listen on a UNIX-domain path using this Socket.
---@param path string
---@return boolean|nil ok, any err
function Socket:listen_unix(path)
	local fd = self:_fd()

	local ok, err = fd_backend.bind(fd, path)
	if not ok then
		return nil, ('bind failed: %s'):format(tostring(err))
	end

	ok, err = fd_backend.listen(fd)
	if not ok then
		return nil, ('listen failed: %s'):format(tostring(err))
	end

	return true
end

----------------------------------------------------------------------
-- accept() as an Op
----------------------------------------------------------------------

--- Build an Op that accepts a connection and returns a Stream.
---@return Op
function Socket:accept_op()
	local P  = poller_mod.get()
	local fd = self:_fd()

	local function step()
		local new_fd, err, again = fd_backend.accept(fd)
		if new_fd then
			return true, new_fd, nil
		end
		if again then
			-- Would block: wait for readability.
			return false
		end
		-- Hard error.
		return true, nil, err
	end

	local function register(task)
		-- poller wait on listening fd for read readiness.
		return P:wait(fd, 'rd', task)
	end

	local function wrap(new_fd, err)
		if not new_fd then
			return nil, err
		end
		-- fd_to_stream will mark it non-blocking via fd_backend.new().
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
-- connect() as an Op (AF_UNIX path as opaque "sa")
----------------------------------------------------------------------

--- Build an Op that connects this Socket to an address token.
--- Currently sa is expected to be a UNIX-domain path string.
---@param sa any
---@return Op
function Socket:connect_op(sa)
	local P     = poller_mod.get()
	local fd    = self:_fd()
	local state = 'initial'

	local function step()
		if state == 'initial' then
			local ok, err, inprogress = fd_backend.connect_start(fd, sa)
			if ok then
				return true, true, nil
			end
			if inprogress then
				state = 'waiting'
				return false
			end
			return true, false, err
		elseif state == 'waiting' then
			local ok, err = fd_backend.connect_finish(fd)
			if not ok then
				return true, false, err
			end
			return true, true, nil
		else
			return true, false, 'invalid connect state'
		end
	end

	local function register(task)
		-- Non-blocking connect completion is signalled via writability.
		return P:wait(fd, 'wr', task)
	end

	local function wrap(ok, err)
		if not ok then
			return nil, err
		end
		local new_fd = fd
		-- Hand ownership of the fd to the Stream; prevent double-close in Socket:close().
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
	return self:connect_op(path)
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

	local stype    = opts.stype or fd_backend.SOCK_STREAM
	local protocol = opts.protocol or 0

	local s, err = socket(fd_backend.AF_UNIX, stype, protocol)
	if not s then
		return nil, err
	end

	local ok, lerr = s:listen_unix(path)
	if not ok then
		s:close()
		return nil, lerr
	end

	if opts.ephemeral then
		local parent_close = s.close
		function s:close()
			local ok1, err1 = parent_close(self)

			local ok2, err2 = fd_backend.unlink(path)
			if not ok2 then
				return false, ('failed to remove %s: %s'):format(
					tostring(path),
					tostring(err2)
				)
			end

			if ok1 == false then
				return false, err1
			end
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
	stype    = stype or fd_backend.SOCK_STREAM
	protocol = protocol or 0

	local s, err = socket(fd_backend.AF_UNIX, stype, protocol)
	if not s then
		return nil, err
	end

	local stream, cerr = s:connect_unix(path)
	if not stream then
		s:close()
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
		local ok, err = fd_backend.close_fd(self.fd)
		self.fd = nil
		return ok, err
	end
	return true, nil
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

return {
	socket       = socket,
	listen_unix  = listen_unix,
	connect_unix = connect_unix,
	Socket       = Socket,

	-- re-export useful constants for callers
	AF_UNIX     = fd_backend.AF_UNIX,
	SOCK_STREAM = fd_backend.SOCK_STREAM,
}

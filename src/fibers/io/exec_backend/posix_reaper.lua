-- fibers/io/exec_backend/posix_reaper.lua
--
-- luaposix-based exec backend using a per-command reaper process and
-- a sentinel pipe for completion notifications.
--
-- This backend is intended for runtimes where a Lua SIGCHLD handler is not
-- safe or reliable, notably LuaJIT + luaposix.  It preserves the evented
-- parent-side model: the scheduler waits for ordinary fd readability on a
-- sentinel pipe rather than polling time.
--
-- Topology per command:
--   parent
--     ├─ reaper process (Lua, this module)
--     │    └─ real child (exec'ed programme)
--     └─ sentinel_r (read end of status pipe)
--
-- Protocol on the sentinel pipe:
--   - reaper writes:   "pid <child_pid>\n"
--   - later writes one of:
--         "exited <code>\n"
--         "signaled <signal>\n"
--         "failed <message>\n"
--
-- Parent uses the Fibers poller to wait for sentinel_r readability. When
-- terminal status arrives, the parent also reaps the intermediate reaper.

---@module 'fibers.io.exec_backend.posix_reaper'

local core    = require 'fibers.io.exec_backend.core'
local poller  = require 'fibers.io.poller'
local runtime = require 'fibers.runtime'
local file_io = require 'fibers.io.file'
local stdio   = require 'fibers.io.exec_backend.stdio'

local ok_unistd, unistd = pcall(require, 'posix.unistd')
local ok_wait, syswait  = pcall(require, 'posix.sys.wait')
local ok_signal, psig   = pcall(require, 'posix.signal')
local ok_fcntl, fcntl   = pcall(require, 'posix.fcntl')
local ok_errno, errno   = pcall(require, 'posix.errno')
local ok_stdlib, stdlib = pcall(require, 'posix.stdlib')

if not (ok_unistd and ok_wait and ok_signal and ok_fcntl and ok_errno and ok_stdlib) then
	return { is_supported = function () return false end }
end

local bit = rawget(_G, 'bit') or require 'bit32'

local DEV_NULL = '/dev/null'

----------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------

local function errno_msg(prefix, err, eno)
	if err and err ~= '' then
		return err
	end
	if eno then
		return ('%s (errno %s)'):format(prefix, tostring(eno))
	end
	return prefix
end

local function close_fd(fd)
	if fd ~= nil then
		pcall(unistd.close, fd)
	end
end

local function set_nonblock(fd)
	local flags, err, eno = fcntl.fcntl(fd, fcntl.F_GETFL)
	if flags == nil then
		return nil, errno_msg('fcntl(F_GETFL)', err, eno)
	end
	local ok, err2, eno2 = fcntl.fcntl(fd, fcntl.F_SETFL, bit.bor(flags, fcntl.O_NONBLOCK))
	if ok == nil then
		return nil, errno_msg('fcntl(F_SETFL)', err2, eno2)
	end
	return true, nil
end

local function set_cloexec(fd)
	if not (fcntl.F_GETFD and fcntl.F_SETFD) then
		return true, nil
	end
	local flags, err, eno = fcntl.fcntl(fd, fcntl.F_GETFD)
	if flags == nil then
		return nil, errno_msg('fcntl(F_GETFD)', err, eno)
	end
	local ok, err2, eno2 = fcntl.fcntl(fd, fcntl.F_SETFD, bit.bor(flags, fcntl.FD_CLOEXEC or 0))
	if ok == nil then
		return nil, errno_msg('fcntl(F_SETFD)', err2, eno2)
	end
	return true, nil
end

local function write_all(fd, s)
	local off = 1
	while off <= #s do
		local n, err, eno = unistd.write(fd, s:sub(off))
		if n == nil then
			if eno == errno.EINTR then
				-- Retry.
			else
				return nil, errno_msg('write', err, eno)
			end
		else
			off = off + n
		end
	end
	return true, nil
end

local function must_child(ok, _, _)
	if not ok or ok == 0 then
		unistd._exit(127)
	end
end

local function build_argt(argv)
	local cmd  = assert(argv[1], 'ProcSpec.argv[1] must be executable')
	local argt = {}
	argt[0]    = cmd
	for i = 2, #argv do
		argt[i - 1] = argv[i]
	end
	return cmd, argt
end

local function setup_child_fd(src_fd, dest_fd)
	if src_fd == nil or src_fd == dest_fd then
		return
	end
	local newfd, err, eno = unistd.dup2(src_fd, dest_fd)
	if not newfd then
		must_child(false, err, eno)
	end
end

local function apply_child_env(env)
	for name, value in pairs(env) do
		local ok, err, eno = stdlib.setenv(name, value and tostring(value) or nil)
		if ok == nil then
			must_child(false, err, eno)
		end
	end
end

----------------------------------------------------------------------
-- Stdio integration for exec_backend.stdio
----------------------------------------------------------------------

local function open_dev_null(is_output)
	local flags = is_output and fcntl.O_WRONLY or fcntl.O_RDONLY
	local fd, err, eno = fcntl.open(DEV_NULL, flags, 0)
	if not fd then
		return nil, errno_msg('failed to open ' .. DEV_NULL, err, eno)
	end
	return fd, nil
end

local function make_pipe()
	local rd, wr, err, eno = unistd.pipe()
	if not rd then
		return nil, nil, errno_msg('pipe() failed', err, eno)
	end
	return rd, wr, nil
end

local function open_stream(role, fd)
	if role == 'stdin' then
		return file_io.fdopen(fd, fcntl.O_WRONLY)
	else
		return file_io.fdopen(fd, fcntl.O_RDONLY)
	end
end

----------------------------------------------------------------------
-- Child exec path
----------------------------------------------------------------------

---@param spec table  -- child-facing spec with *fd fields
---@param child_only table<any, boolean>|nil
---@param parent_fds table<string, any|nil>|nil
---@param sentinel_w integer|nil
local function child_exec(spec, child_only, parent_fds, sentinel_w)
	-- The real child must not keep the sentinel writer open across exec.
	close_fd(sentinel_w)

	if spec.cwd then
		local ok, err, eno = unistd.chdir(spec.cwd)
		if not ok then
			must_child(false, err, eno)
		end
	end

	if spec.flags and spec.flags.setsid then
		local res, err, eno
		if unistd.setsid then
			res, err, eno = unistd.setsid()
		elseif unistd.setpid then
			res, err, eno = unistd.setpid('s', 0)
		end
		if res == nil then
			must_child(false, err, eno)
		end
	end

	if spec.env then
		apply_child_env(spec.env)
	end

	setup_child_fd(spec.stdin_fd, 0)
	setup_child_fd(spec.stdout_fd, 1)
	setup_child_fd(spec.stderr_fd, 2)

	stdio.close_child_only(child_only, close_fd)
	stdio.close_parent_fds(parent_fds, close_fd)

	local cmd, argt = build_argt(spec.argv)
	unistd.execp(cmd, argt)
	unistd._exit(127)
end

----------------------------------------------------------------------
-- Reaper process path
----------------------------------------------------------------------

local function wait_blocking(pid)
	while true do
		local rpid, how, value, err, eno = syswait.wait(pid)
		if rpid ~= nil then
			return rpid, how, value, nil, nil
		end
		if eno ~= errno.EINTR then
			return nil, nil, nil, err, eno
		end
	end
end

--- Run in the per-command reaper process.
---@param child_spec table
---@param child_only table<any, boolean>|nil
---@param parent_fds table<string, any|nil>|nil
---@param sentinel_r integer
---@param sentinel_w integer
local function reaper_main(child_spec, child_only, parent_fds, sentinel_r, sentinel_w)
	-- The reaper does not need parent pipe ends or the parent's sentinel read end.
	stdio.close_parent_fds(parent_fds, close_fd)
	close_fd(sentinel_r)

	local child_pid, err, eno = unistd.fork()
	if not child_pid then
		write_all(sentinel_w, 'failed ' .. errno_msg('fork child', err, eno) .. '\n')
		close_fd(sentinel_w)
		unistd._exit(127)
	end

	if child_pid == 0 then
		child_exec(child_spec, child_only, parent_fds, sentinel_w)
		unistd._exit(127)
	end

	-- In the reaper.
	stdio.close_child_only(child_only, close_fd)
	write_all(sentinel_w, ('pid %d\n'):format(child_pid))

	local pid, how, what, werr, weno = wait_blocking(child_pid)
	local line
	if not pid then
		line = 'failed ' .. errno_msg('wait child', werr, weno) .. '\n'
	elseif how == 'exited' then
		line = ('exited %d\n'):format(tonumber(what) or 0)
	else
		line = ('signaled %d\n'):format(tonumber(what) or 0)
	end

	write_all(sentinel_w, line)
	close_fd(sentinel_w)
	unistd._exit(0)
end

----------------------------------------------------------------------
-- Backend state helpers and parsing
----------------------------------------------------------------------

---@class PosixReaperState
---@field reaper_pid integer
---@field pid integer|nil
---@field child_pid integer|nil
---@field sentinel integer|nil
---@field exited boolean
---@field code integer|nil
---@field signal integer|nil
---@field err string|nil
---@field _buf string|nil
---@field _have_status boolean|nil
---@field _reaper_reaped boolean|nil

local function parse_status_line_into_state(line, state)
	line = line:gsub('\r', '')
	local tag, rest = line:match('^(%S+)%s*(.*)$')
	if tag == 'pid' then
		local cpid = tonumber(rest)
		if cpid then
			state.child_pid = cpid
			state.pid       = cpid
		end
		return
	elseif tag == 'exited' then
		state.code         = tonumber(rest) or 0
		state.signal       = nil
		state.err          = state.err or nil
		state.exited       = true
		state._have_status = true
		return
	elseif tag == 'signaled' or tag == 'signalled' then
		state.code         = nil
		state.signal       = tonumber(rest) or 0
		state.err          = state.err or nil
		state.exited       = true
		state._have_status = true
		return
	elseif tag == 'failed' then
		state.code         = nil
		state.signal       = nil
		state.err          = rest ~= '' and rest or 'exec backend failed'
		state.exited       = true
		state._have_status = true
		return
	end

	state.code         = nil
	state.signal       = nil
	state.err          = 'unknown status line from reaper: ' .. tostring(line)
	state.exited       = true
	state._have_status = true
end

local function reap_reaper(state, blocking)
	if state._reaper_reaped or not state.reaper_pid then
		return
	end

	while true do
		local pid, how, _, err, eno
		if blocking then
			pid, how, _, err, eno = syswait.wait(state.reaper_pid)
		else
			pid, how, _, err, eno = syswait.wait(state.reaper_pid, syswait.WNOHANG)
		end

		if pid == nil then
			if eno == errno.EINTR then
				-- Retry.
			elseif eno == errno.ECHILD then
				state._reaper_reaped = true
				return
			else
				state.err = state.err or errno_msg('wait reaper', err, eno)
				return
			end
		elseif pid == 0 or how == 'running' then
			return
		else
			state._reaper_reaped = true
			return
		end
	end
end

local function drain_sentinel(state)
	local fd = state.sentinel
	if not fd then
		return
	end

	while true do
		local chunk, err, eno = unistd.read(fd, 4096)
		if chunk == nil then
			if eno == errno.EAGAIN or eno == errno.EWOULDBLOCK or eno == errno.EINTR then
				break
			end
			close_fd(fd)
			state.sentinel = nil
			if not state._have_status then
				state.exited = true
				state.err    = state.err or errno_msg('read sentinel', err, eno)
			end
			reap_reaper(state, true)
			break
		end

		if #chunk == 0 then
			close_fd(fd)
			state.sentinel = nil
			if not state._have_status then
				state.exited = true
				state.err    = state.err or 'reaper sentinel closed'
			end
			reap_reaper(state, true)
			break
		end

		state._buf = (state._buf or '') .. chunk

		while true do
			local line, rest = state._buf:match('^(.-)\n(.*)$')
			if not line then
				break
			end
			state._buf = rest
			parse_status_line_into_state(line, state)
		end

		if state.exited then
			close_fd(fd)
			state.sentinel = nil
			reap_reaper(state, true)
			break
		end
	end
end

----------------------------------------------------------------------
-- exec_backend.core ops
----------------------------------------------------------------------

---@param spec ExecProcSpec
---@return PosixReaperState|nil state,{stdin:Stream|nil,stdout:Stream|nil,stderr:Stream|nil}|nil streams,string|nil err
local function spawn(spec)
	assert(type(spec) == 'table', 'ExecBackend.spawn: spec must be a table')
	assert(type(spec.argv) == 'table' and spec.argv[1],
		'ExecBackend.spawn: spec.argv must be a non-empty array')

	local child_spec, child_only, parent_fds, cfg_err =
		stdio.build_child_stdio(spec, open_dev_null, make_pipe, set_cloexec, close_fd)
	if not child_spec then
		return nil, nil, cfg_err
	end

	local sentinel_r, sentinel_w, serr = make_pipe()
	if not sentinel_r then
		stdio.close_child_only(child_only, close_fd)
		stdio.close_parent_fds(parent_fds, close_fd)
		return nil, nil, serr or 'pipe (sentinel) failed'
	end

	set_cloexec(sentinel_r)
	set_cloexec(sentinel_w)

	local reaper_pid, ferr, feno = unistd.fork()
	if not reaper_pid then
		stdio.close_child_only(child_only, close_fd)
		stdio.close_parent_fds(parent_fds, close_fd)
		close_fd(sentinel_r)
		close_fd(sentinel_w)
		return nil, nil, errno_msg('fork reaper', ferr, feno)
	end

	if reaper_pid == 0 then
		reaper_main(child_spec, child_only, parent_fds, sentinel_r, sentinel_w)
		unistd._exit(127)
	end

	-- Parent.
	stdio.close_child_only(child_only, close_fd)
	close_fd(sentinel_w)

	local state = {
		reaper_pid     = reaper_pid,
		pid            = reaper_pid, -- updated to child pid by handshake
		child_pid      = nil,
		sentinel       = sentinel_r,
		exited         = false,
		code           = nil,
		signal         = nil,
		err            = nil,
		_buf           = '',
		_have_status   = false,
		_reaper_reaped = false,
	}

	-- Handshake: block only at spawn time until the reaper has reported the
	-- real child pid or a terminal failure. This guarantees send_signal()
	-- targets the exec child rather than the intermediate reaper.
	while not state.child_pid and not state._have_status do
		local chunk, rerr, reno = unistd.read(sentinel_r, 4096)
		if chunk == nil then
			close_fd(sentinel_r)
			state.sentinel = nil
			reap_reaper(state, false)
			stdio.close_parent_fds(parent_fds, close_fd)
			return nil, nil, errno_msg('sentinel handshake read', rerr, reno)
		end
		if #chunk == 0 then
			close_fd(sentinel_r)
			state.sentinel = nil
			reap_reaper(state, false)
			stdio.close_parent_fds(parent_fds, close_fd)
			return nil, nil, 'sentinel closed during handshake'
		end

		state._buf = (state._buf or '') .. chunk
		while true do
			local line, rest = state._buf:match('^(.-)\n(.*)$')
			if not line then
				break
			end
			state._buf = rest
			parse_status_line_into_state(line, state)
		end
	end

	local ok_nb, nb_err = set_nonblock(sentinel_r)
	if not ok_nb then
		close_fd(sentinel_r)
		state.sentinel = nil
		stdio.close_parent_fds(parent_fds, close_fd)
		return nil, nil, nb_err
	end

	local streams = stdio.build_parent_streams(parent_fds, open_stream)
	return state, streams, nil
end

local function poll_backend(state)
	if state.exited then
		return true, state.code, state.signal, state.err
	end
	drain_sentinel(state)
	if state.exited then
		return true, state.code, state.signal, state.err
	end
	return false, nil, nil, nil
end

local function register_wait(state, task, _, _)
	if not state.sentinel then
		local sched = runtime.current_scheduler
		if sched and sched.schedule then
			sched:schedule(task)
		end
		return { unlink = function () return false end }
	end
	return poller.get():wait(state.sentinel, 'rd', task)
end

local function send_signal(state, sig)
	sig = sig or psig.SIGTERM or 15

	if state.exited then
		return true, nil
	end

	drain_sentinel(state)
	if state.exited then
		return true, nil
	end

	local target = state.child_pid or state.pid or state.reaper_pid
	if not target then
		return false, 'no child or reaper pid available'
	end

	local rc, err, eno = psig.kill(target, sig)
	if rc == 0 then
		return true, nil
	end
	if rc == nil and eno == errno.ESRCH then
		return true, nil
	end
	return false, errno_msg('kill failed', err, eno)
end

local function terminate(state)
	return send_signal(state, psig.SIGTERM or 15)
end

local function kill_proc(state)
	return send_signal(state, psig.SIGKILL or 9)
end

local function close_state(state)
	close_fd(state.sentinel)
	state.sentinel = nil
	-- Terminal commands should reap the intermediate reaper synchronously so
	-- completed commands do not accumulate as zombies.  If close() is used on a
	-- still-running backend, keep non-blocking behaviour.
	reap_reaper(state, state.exited or state._have_status)
	return true, nil
end

local function is_supported()
	return type(unistd.fork) == 'function'
		and type(unistd.execp) == 'function'
		and type(unistd.pipe) == 'function'
		and type(unistd.read) == 'function'
		and type(unistd.write) == 'function'
		and type(unistd._exit) == 'function'
		and type(syswait.wait) == 'function'
		and syswait.WNOHANG ~= nil
		and type(psig.kill) == 'function'
		and type(fcntl.open) == 'function'
end

local ops = {
	spawn         = spawn,
	poll          = poll_backend,
	register_wait = register_wait,
	send_signal   = send_signal,
	terminate     = terminate,
	kill          = kill_proc,
	close         = close_state,
	is_supported  = is_supported,
}

return core.build_backend(ops)

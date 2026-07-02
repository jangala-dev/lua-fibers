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
local reaper_common = require 'fibers.io.exec_backend.reaper_common'

local ok_unistd, unistd = pcall(require, 'posix.unistd')
local ok_wait, syswait  = pcall(require, 'posix.sys.wait')
local ok_signal, psig   = pcall(require, 'posix.signal')
local ok_fcntl, fcntl   = pcall(require, 'posix.fcntl')
local ok_errno, errno   = pcall(require, 'posix.errno')
local ok_stdlib, stdlib = pcall(require, 'posix.stdlib')
local ok_time, ptime   = pcall(require, 'posix.time')
local ok_prctl, prctl_mod = pcall(require, 'posix.sys.prctl')
local ok_ffi, ffi = pcall(require, 'ffi')
local C
local have_ffi_prctl = false
local have_ffi_setpgid = false
if ok_ffi and ffi then
	pcall(function ()
		ffi.cdef [[
		  typedef int pid_t;
		  int prctl(int option, unsigned long arg2, unsigned long arg3, unsigned long arg4, unsigned long arg5);
		  int setpgid(pid_t pid, pid_t pgid);
		]]
	end)
	C = ffi.C
	have_ffi_prctl = pcall(function () return C.prctl end)
	have_ffi_setpgid = pcall(function () return C.setpgid end)
end

if not (ok_unistd and ok_wait and ok_signal and ok_fcntl and ok_errno and ok_stdlib) then
	return { is_supported = function () return false end }
end

local bit = rawget(_G, 'bit') or require 'bit32'

local DEV_NULL = '/dev/null'
local PR_SET_PDEATHSIG = 1

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

local function pdeathsig_supported()
	return (ok_prctl and prctl_mod and type(prctl_mod.prctl) == 'function')
		or (C and have_ffi_prctl)
end

local function parent_death_signal_supported()
	-- parent_death_signal is the reaper-backed emulation.  Native
	-- PR_SET_PDEATHSIG remains exposed separately as flags.pdeathsig.
	return ok_time and ptime and type(ptime.nanosleep) == 'function'
end

local function apply_pdeathsig_child(sig)
	if ok_prctl and prctl_mod and type(prctl_mod.prctl) == 'function' then
		local ok, err, eno = prctl_mod.prctl(prctl_mod.PR_SET_PDEATHSIG or PR_SET_PDEATHSIG, sig)
		if ok == nil or ok == -1 then
			must_child(false, err, eno)
		end
		return
	end

	if C and have_ffi_prctl then
		local rc = C.prctl(PR_SET_PDEATHSIG, sig, 0, 0, 0)
		must_child(rc == 0)
		return
	end

	must_child(false)
end

local function process_group_supported()
	return type(unistd.setpgid) == 'function'
		or type(unistd.setpid) == 'function'
		or (C and have_ffi_setpgid)
end

local function set_process_group_child()
	local res, err, eno
	if type(unistd.setpgid) == 'function' then
		res, err, eno = unistd.setpgid(0, 0)
	elseif type(unistd.setpid) == 'function' then
		res, err, eno = unistd.setpid('p', 0, 0)
	elseif C and have_ffi_setpgid then
		res = C.setpgid(0, 0)
		must_child(res == 0)
		return
	else
		must_child(false)
	end
	if res == nil then
		must_child(false, err, eno)
	end
end

local function set_process_group_parent(pid)
	if type(unistd.setpgid) == 'function' then
		pcall(unistd.setpgid, pid, pid)
	elseif type(unistd.setpid) == 'function' then
		pcall(unistd.setpid, 'p', pid, pid)
	elseif C and have_ffi_setpgid then
		pcall(function () C.setpgid(pid, pid) end)
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

	if spec.flags and spec.flags.pdeathsig then
		apply_pdeathsig_child(spec.flags.pdeathsig)
	end

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
	elseif spec.flags and spec.flags.process_group then
		set_process_group_child()
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
local function parent_liveness_closed(fd)
	if not fd then
		return false
	end
	local chunk, err, eno = unistd.read(fd, 1)
	if chunk ~= nil then
		return #chunk == 0
	end
	if eno == errno.EAGAIN or eno == errno.EWOULDBLOCK or eno == errno.EINTR then
		return false
	end
	return true
end

local function sleep_parent_death_poll_interval()
	if not (ok_time and ptime and type(ptime.nanosleep) == 'function') then
		return
	end
	local req = { tv_sec = 0, tv_nsec = 100000000 }
	while true do
		local ok, _, eno, rem = ptime.nanosleep(req)
		if ok or eno ~= errno.EINTR then
			return
		end
		req = rem or req
	end
end

local function reaper_main(child_spec, child_only, parent_fds, sentinel_r, sentinel_w, parent_live_r, parent_live_w)
	-- The reaper does not need parent pipe ends, the parent's sentinel read end,
	-- or the parent's liveness write end.
	stdio.close_parent_fds(parent_fds, close_fd)
	close_fd(sentinel_r)
	close_fd(parent_live_w)

	if child_spec.flags and child_spec.flags.pdeathsig then
		apply_pdeathsig_child(child_spec.flags.pdeathsig)
	end

	local child_pid, err, eno = unistd.fork()
	if not child_pid then
		write_all(sentinel_w, 'failed ' .. errno_msg('fork child', err, eno) .. '\n')
		close_fd(sentinel_w)
		unistd._exit(127)
	end

	if child_pid == 0 then
		close_fd(parent_live_r)
		child_exec(child_spec, child_only, parent_fds, sentinel_w)
		unistd._exit(127)
	end

	if child_spec.flags and child_spec.flags.process_group then
		set_process_group_parent(child_pid)
	end

	-- In the reaper.
	stdio.close_child_only(child_only, close_fd)
	write_all(sentinel_w, ('pid %d\n'):format(child_pid))

	local parent_death_signal = child_spec.flags and child_spec.flags.parent_death_signal or nil
	local use_emulated_parent_death = parent_death_signal ~= nil
	local sent_parent_death_signal = false
	local parent_lost = false

	local pid, how, what, werr, weno
	if use_emulated_parent_death then
		while true do
			pid, how, what, werr, weno = syswait.wait(child_pid, syswait.WNOHANG)
			if pid and pid ~= 0 then
				break
			end
			if pid == nil and weno ~= errno.EINTR then
				break
			end

			if not sent_parent_death_signal and parent_liveness_closed(parent_live_r) then
				parent_lost = true
				local target = (child_spec.flags and child_spec.flags.process_group) and -child_pid or child_pid
				psig.kill(target, parent_death_signal)
				sent_parent_death_signal = true
			end

			sleep_parent_death_poll_interval()
		end
	else
		pid, how, what, werr, weno = wait_blocking(child_pid)
	end

	close_fd(parent_live_r)

	local line
	if not pid then
		line = 'failed ' .. errno_msg('wait child', werr, weno) .. '\n'
	elseif how == 'exited' then
		line = ('exited %d\n'):format(tonumber(what) or 0)
	else
		line = ('signaled %d\n'):format(tonumber(what) or 0)
	end

	-- If the parent has died there may be no reader for the sentinel.  Avoid
	-- writing in the common emulated-parent-death case; the child has already
	-- been reaped and there is no parent left to consume the status.
	if not (use_emulated_parent_death and parent_lost) then
		write_all(sentinel_w, line)
	end
	close_fd(sentinel_w)
	unistd._exit(0)
end

----------------------------------------------------------------------
-- Parent-side reaper helpers
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

local function read_sentinel(fd)
	local chunk, err, eno = unistd.read(fd, 4096)
	if chunk == nil then
		if eno == errno.EAGAIN or eno == errno.EWOULDBLOCK or eno == errno.EINTR then
			return nil, 'wait', nil
		end
		return nil, 'error', errno_msg('read sentinel', err, eno)
	end
	if #chunk == 0 then
		return nil, 'eof', nil
	end
	return chunk, 'data', nil
end

local reaper_ops = {
	read_sentinel = read_sentinel,
	close_fd      = close_fd,
	reap_reaper   = reap_reaper,
	kill_pid      = nil, -- filled after send_signal helpers are defined
	default_term  = psig.SIGTERM or 15,
}

----------------------------------------------------------------------
-- exec_backend.core ops
----------------------------------------------------------------------

---@param spec ExecProcSpec
---@return PosixReaperState|nil state,{stdin:Stream|nil,stdout:Stream|nil,stderr:Stream|nil}|nil streams,string|nil err
local function spawn(spec)
	assert(type(spec) == 'table', 'ExecBackend.spawn: spec must be a table')
	assert(type(spec.argv) == 'table' and spec.argv[1],
		'ExecBackend.spawn: spec.argv must be a non-empty array')

	if spec.flags and spec.flags.pdeathsig and not pdeathsig_supported() then
		return nil, nil, 'flags.pdeathsig is not supported by posix_reaper exec backend'
	end
	if spec.flags and spec.flags.parent_death_signal and not parent_death_signal_supported() then
		return nil, nil, 'flags.parent_death_signal is not supported by posix_reaper exec backend'
	end
	if spec.flags and spec.flags.process_group and not process_group_supported() then
		return nil, nil, 'flags.process_group is not supported by posix_reaper exec backend'
	end

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

	local parent_live_r, parent_live_w
	if spec.flags and spec.flags.parent_death_signal then
		parent_live_r, parent_live_w, serr = make_pipe()
		if not parent_live_r then
			stdio.close_child_only(child_only, close_fd)
			stdio.close_parent_fds(parent_fds, close_fd)
			close_fd(sentinel_r)
			close_fd(sentinel_w)
			return nil, nil, serr or 'pipe (parent liveness) failed'
		end
		set_cloexec(parent_live_r)
		set_cloexec(parent_live_w)
		set_nonblock(parent_live_r)
	end

	local reaper_pid, ferr, feno = unistd.fork()
	if not reaper_pid then
		stdio.close_child_only(child_only, close_fd)
		stdio.close_parent_fds(parent_fds, close_fd)
		close_fd(sentinel_r)
		close_fd(sentinel_w)
		close_fd(parent_live_r)
		close_fd(parent_live_w)
		return nil, nil, errno_msg('fork reaper', ferr, feno)
	end

	if reaper_pid == 0 then
		reaper_main(child_spec, child_only, parent_fds, sentinel_r, sentinel_w, parent_live_r, parent_live_w)
		unistd._exit(127)
	end

	-- Parent.
	stdio.close_child_only(child_only, close_fd)
	close_fd(sentinel_w)
	close_fd(parent_live_r)

	local state = reaper_common.new_state(reaper_pid, sentinel_r, {
		signal_process_group = spec.flags and spec.flags.process_group,
	})
	state.parent_live_w = parent_live_w

	-- Handshake: block only at spawn time until the reaper has reported the
	-- real child pid or a terminal failure. This guarantees send_signal()
	-- targets the exec child rather than the intermediate reaper.
	while not state.child_pid and not state._have_status do
		local chunk, rerr, reno = unistd.read(sentinel_r, 4096)
		if chunk == nil then
			close_fd(sentinel_r)
			close_fd(parent_live_w)
			state.parent_live_w = nil
			state.sentinel = nil
			reap_reaper(state, false)
			stdio.close_parent_fds(parent_fds, close_fd)
			return nil, nil, errno_msg('sentinel handshake read', rerr, reno)
		end
		if #chunk == 0 then
			close_fd(sentinel_r)
			close_fd(parent_live_w)
			state.parent_live_w = nil
			state.sentinel = nil
			reap_reaper(state, false)
			stdio.close_parent_fds(parent_fds, close_fd)
			return nil, nil, 'sentinel closed during handshake'
		end

		reaper_common.feed_status_chunk(state, chunk)
	end

	local ok_nb, nb_err = set_nonblock(sentinel_r)
	if not ok_nb then
		close_fd(sentinel_r)
		close_fd(parent_live_w)
		state.parent_live_w = nil
		state.sentinel = nil
		stdio.close_parent_fds(parent_fds, close_fd)
		return nil, nil, nb_err
	end

	local streams = stdio.build_parent_streams(parent_fds, open_stream)
	return state, streams, nil
end

local function poll_backend(state)
	return reaper_common.poll_state(state, reaper_ops)
end

local function register_wait(state, task, _, _)
	return reaper_common.register_wait(state, task)
end

local function kill_pid(pid, sig)
	local rc, err, eno = psig.kill(pid, sig)
	if rc == 0 then
		return true, nil
	end
	if rc == nil and eno == errno.ESRCH then
		return true, nil
	end
	return false, errno_msg('kill failed', err, eno)
end

reaper_ops.kill_pid = kill_pid

local function send_signal(state, sig)
	return reaper_common.send_signal(state, sig, reaper_ops)
end

local function terminate(state)
	return send_signal(state, psig.SIGTERM or 15)
end

local function kill_proc(state)
	return send_signal(state, psig.SIGKILL or 9)
end

local function close_state(state)
	if state.parent_live_w then
		close_fd(state.parent_live_w)
		state.parent_live_w = nil
	end
	return reaper_common.close_state(state, reaper_ops)
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
	features      = function () return { pdeathsig = pdeathsig_supported(), parent_death_signal = parent_death_signal_supported(), process_group = process_group_supported() } end,
	is_supported  = is_supported,
}

return core.build_backend(ops)

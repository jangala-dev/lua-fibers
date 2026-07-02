-- fibers/io/exec_backend/reaper_common.lua
--
-- Shared parent-side support for exec backends that use a per-command
-- reaper process and a sentinel pipe.  Backend-specific modules still own
-- fork/exec, stdio setup and fd operations; this module owns only the common
-- sentinel protocol and parent-side state transitions.
--
-- Sentinel protocol:
--   pid <child_pid>\n
--   exited <code>\n
--   signaled <signal>\n
--   failed <message>\n

---@module 'fibers.io.exec_backend.reaper_common'

local poller  = require 'fibers.io.poller'
local runtime = require 'fibers.runtime'

local M = {}

---@param reaper_pid integer
---@param sentinel any
---@param opts table|nil
---@return table
function M.new_state(reaper_pid, sentinel, opts)
	opts = opts or {}
	return {
		reaper_pid           = reaper_pid,
		pid                  = reaper_pid, -- updated to child pid by pid line
		child_pid            = nil,
		pgid                 = nil,
		signal_process_group = opts.signal_process_group and true or nil,
		sentinel             = sentinel,
		exited         = false,
		code           = nil,
		signal         = nil,
		err            = nil,
		_buf           = '',
		_have_status   = false,
		_reaper_reaped = false,
	}
end

---@param line string
---@param state table
function M.parse_status_line_into_state(line, state)
	line = tostring(line or ''):gsub('\r', '')
	local tag, rest = line:match('^(%S+)%s*(.*)$')

	if tag == 'pid' then
		local cpid = tonumber(rest)
		if cpid then
			state.child_pid = cpid
			state.pid       = cpid
			if state.signal_process_group then
				state.pgid = cpid
			end
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

---@param state table
---@param chunk string
function M.feed_status_chunk(state, chunk)
	if not chunk or chunk == '' then
		return
	end

	state._buf = (state._buf or '') .. chunk

	while true do
		local line, rest = state._buf:match('^(.-)\n(.*)$')
		if not line then
			break
		end
		state._buf = rest
		M.parse_status_line_into_state(line, state)
	end
end

local function close_sentinel(state, ops)
	if state.sentinel ~= nil then
		ops.close_fd(state.sentinel)
		state.sentinel = nil
	end
end

---@param state table
---@param ops table backend operations
local function mark_sentinel_gone(state, ops, err)
	close_sentinel(state, ops)
	if not state._have_status then
		state.exited = true
		state.err    = state.err or err or 'reaper sentinel closed'
	end
	ops.reap_reaper(state, true)
end

---@param state table
---@param ops table backend operations
function M.drain_sentinel(state, ops)
	local sentinel = state.sentinel
	if not sentinel then
		return
	end

	while true do
		local chunk, status, err = ops.read_sentinel(sentinel)

		if chunk ~= nil then
			if #chunk == 0 then
				mark_sentinel_gone(state, ops, 'reaper sentinel closed')
				break
			end

			M.feed_status_chunk(state, chunk)

			if state.exited then
				close_sentinel(state, ops)
				ops.reap_reaper(state, true)
				break
			end
		elseif status == 'wait' then
			break
		elseif status == 'eof' then
			mark_sentinel_gone(state, ops, 'reaper sentinel closed')
			break
		else
			mark_sentinel_gone(state, ops, err or 'read sentinel failed')
			break
		end
	end
end

---@param state table
---@param ops table backend operations
---@return boolean done, integer|nil code, integer|nil signal, string|nil err
function M.poll_state(state, ops)
	if state.exited then
		return true, state.code, state.signal, state.err
	end

	if not state.sentinel then
		if not state._have_status then
			state.exited = true
			state.err    = state.err or 'reaper sentinel closed'
		end
		ops.reap_reaper(state, true)
		return true, state.code, state.signal, state.err
	end

	M.drain_sentinel(state, ops)

	if state.exited then
		return true, state.code, state.signal, state.err
	end
	return false, nil, nil, nil
end

---@param state table
---@param task table
---@return table token
function M.register_wait(state, task)
	if not state.sentinel then
		local sched = runtime.current_scheduler
		if sched and sched.schedule then
			sched:schedule(task)
		end
		return { unlink = function () return false end }
	end

	return poller.get():wait(state.sentinel, 'rd', task)
end

---@param state table
---@param sig integer|nil
---@param ops table backend operations
---@return boolean ok, string|nil err
function M.send_signal(state, sig, ops)
	sig = sig or ops.default_term or 15

	if state.exited then
		return true, nil
	end

	M.poll_state(state, ops)
	if state.exited then
		return true, nil
	end

	local target
	if state.signal_process_group and state.pgid then
		target = -state.pgid
	else
		target = state.child_pid or state.pid or state.reaper_pid
	end
	if not target then
		return false, 'no child or reaper pid available'
	end

	return ops.kill_pid(target, sig)
end

---@param state table
---@param ops table backend operations
---@return boolean ok, string|nil err
function M.close_state(state, ops)
	close_sentinel(state, ops)
	-- Terminal commands should reap the intermediate reaper synchronously so
	-- completed commands do not accumulate as zombies.  If close() is used on a
	-- still-running backend, keep non-blocking behaviour.
	ops.reap_reaper(state, state.exited or state._have_status)
	return true, nil
end

return M

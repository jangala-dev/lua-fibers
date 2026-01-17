-- fibers/io/stream.lua
---@module 'fibers.io.stream'

local wait    = require 'fibers.wait'
local bytes   = require 'fibers.utils.bytes'
local op      = require 'fibers.op'
local perform = require 'fibers.performer'.perform
local runtime = require 'fibers.runtime'

local RingBuf   = bytes.RingBuf
local LinearBuf = bytes.LinearBuf

---@class StreamBackend
---@field read_string fun(self: StreamBackend, max: integer): string|nil, any|nil, any|nil
---@field write_string fun(self: StreamBackend, data: string): integer|nil, any|nil, any|nil
---@field on_readable fun(self: StreamBackend, task: Task): WaitToken
---@field on_writable fun(self: StreamBackend, task: Task): WaitToken
---@field close fun(self: StreamBackend): boolean, any|nil
---@field seek fun(self: StreamBackend, whence: string, offset: integer): integer|nil, any|nil
---@field nonblock fun(self: StreamBackend)|nil
---@field block fun(self: StreamBackend)|nil
---@field filename string|nil
---@field fileno fun(self: StreamBackend): integer|nil

---@class Stream
---@field io StreamBackend|nil
---@field rx any|nil
---@field tx any|nil
---@field line_buffering boolean
---@field _ws Waitset
---@field _closed boolean
---@field _sticky_rerr any|nil
---@field _sticky_werr any|nil
---@field _big string|nil
---@field _big_off integer
---@field _pump_task Task
---@field _pump_token WaitToken|nil
---@field _pump_scheduled boolean
---@field _wr_owner any|nil
local Stream = {}
Stream.__index = Stream

local DEFAULT_BUFFER_SIZE = 2 ^ 12

-- Internal wait keys (not exposed).
local K_TERM   = 'term'
local K_SPACE  = 'space'
local K_DRAIN  = 'drain'
local K_WRGATE = 'wr_gate'

----------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------

local function sched()
	return runtime.current_scheduler
end

local function token2(t1, t2)
	return {
		unlink = function ()
			if t1 and t1.unlink then t1:unlink() end
			if t2 and t2.unlink then t2:unlink() end
		end,
	}
end

local NO_TOKEN = { unlink = function () end }

local function notify_all(self, key) self._ws:notify_all(key, sched()) end

local function notify_one(self, key) self._ws:notify_one(key, sched()) end

local function reg_term(self, task) return self._ws:add(K_TERM, task) end

local function reg_internal(self, key, task) return self._ws:add(key, task) end

local function with_term(self, task, tok) return token2(tok or NO_TOKEN, reg_term(self, task)) end

local function with_term_internal(self, task, key)
	return token2(reg_internal(self, key, task), reg_term(self, task))
end

local function broadcast(self)
	notify_all(self, K_TERM)
	notify_all(self, K_SPACE)
	notify_all(self, K_DRAIN)
	notify_all(self, K_WRGATE)
end

----------------------------------------------------------------------
-- Construction
----------------------------------------------------------------------

---@param io_backend StreamBackend
---@param readable? boolean
---@param writable? boolean
---@param bufsize? integer
---@return Stream
local function open(io_backend, readable, writable, bufsize)
	bufsize = bufsize or DEFAULT_BUFFER_SIZE

	local s = setmetatable({
		io              = io_backend,
		line_buffering  = false,
		_ws             = wait.new_waitset(),
		_closed         = false,
		_sticky_rerr    = nil,
		_sticky_werr    = nil,
		_big            = nil,
		_big_off        = 0,
		_pump_token     = nil,
		_pump_scheduled = false,
		_wr_owner       = nil,
	}, Stream)

	if readable ~= false then
		s.rx = RingBuf.new(bufsize)
	end
	if writable ~= false then
		s.tx = RingBuf.new(bufsize)
	end

	s._pump_task = {
		run = function ()
			s:_pump()
		end,
	}

	return s
end

---@param x any
---@return boolean
local function is_stream(x)
	return type(x) == 'table' and getmetatable(x) == Stream
end

function Stream:nonblock()
	if self.io and self.io.nonblock then self.io:nonblock() end
end

function Stream:block()
	if self.io and self.io.block then self.io:block() end
end

----------------------------------------------------------------------
-- Termination / close
----------------------------------------------------------------------

function Stream:_unlink_pump_wait()
	local pt = self._pump_token
	self._pump_token = nil
	if pt and pt.unlink then pt:unlink() end
end

function Stream:terminate(_)
	-- Idempotent: always wake waiters.
	if self._closed then
		return broadcast(self)
	end

	self._closed = true

	-- Cancel any outstanding pump wait.
	self:_unlink_pump_wait()

	local io = self.io
	self.io = nil

	-- Drop buffers immediately.
	self.rx, self.tx = nil, nil
	self._big, self._big_off = nil, 0

	if io and io.close then
		pcall(function () io:close() end)
	end

	return broadcast(self)
end

---@return Op
function Stream:close_op()
	-- Close is graceful on writable streams (flush then terminate),
	-- and immediate on read-only streams.
	if not self.tx then
		return op.always(true, nil):wrap(function (ok, err)
			self:terminate('closed')
			return ok, err
		end)
	end

	return self:flush_op():wrap(function (ok, err)
		self:terminate('closed')
		if ok == nil then
			return nil, err
		end
		return true, nil
	end)
end

function Stream:close()
	return perform(self:close_op())
end

----------------------------------------------------------------------
-- Read path
----------------------------------------------------------------------

---@param stream Stream
---@param buf any
---@param min integer
---@param max integer
---@param terminator string|nil
---@return fun(): boolean, ...
local function make_read_step(stream, buf, min, max, terminator)
	local tally      = 0
	local found_term = false

	local function adjust_for_terminator()
		if not terminator then return end
		local loc = stream.rx:find(terminator)
		if loc then
			found_term = true
			local final = tally + loc + #terminator
			if final <= max then
				min, max = final, final
			end
		end
	end

	return function ()
		while true do
			if stream._sticky_rerr then
				return true, buf, tally, stream._sticky_rerr, found_term
			end

			-- Closed beats capability checks: a previously-readable stream that is
			-- closed must report 'closed', not 'not readable'.
			if stream._closed or not stream.io then
				return true, buf, tally, 'closed', found_term
			end

			if not stream.rx then
				return true, buf, tally, 'not readable', found_term
			end

			adjust_for_terminator()

			local avail = stream.rx:read_avail()
			if avail > 0 and tally < max then
				local need  = math.min(avail, max - tally)
				local chunk = stream.rx:take(need)
				if #chunk > 0 then
					buf:append(chunk)
					tally = tally + #chunk
					if tally >= min then
						return true, buf, tally, nil, found_term
					end
				end
			end

			local io = stream.io
			if not (io and io.read_string) then
				return true, buf, tally, 'backend does not support read_string', found_term
			end

			local room = stream.rx:write_avail()
			if room <= 0 then
				return true, buf, tally, 'buffer capacity exhausted', found_term
			end

			local data, err, want = io:read_string(room)
			if err then
				stream._sticky_rerr = err
				return true, buf, tally, err, found_term
			end

			if data == nil then
				return false, want
			end

			if data == '' then
				return true, buf, tally, nil, found_term
			end

			stream.rx:put(data)
		end
	end
end

function Stream:read_into_op(buf, opts)
	assert(self.rx, 'stream is not readable')

	opts             = opts or {}
	local min        = opts.min or 1
	local max        = opts.max or min
	local terminator = opts.terminator
	local eof_ok     = not not opts.eof_ok

	local step = make_read_step(self, buf, min, max, terminator)

	local function register(task, suspension, _, want)
		local io = self.io
		if not io then
			-- ensure the task runs again and the step observes closure
			suspension.sched:schedule(task)
			return with_term(self, task, NO_TOKEN)
		end

		if want == 'wr' and io.on_writable then
			return with_term(self, task, io:on_writable(task))
		end
		return with_term(self, task, io:on_readable(task))
	end

	local ev = wait.waitable2(register, step, step)

	return ev:wrap(function (ret_buf, cnt, err, found_term)
		if cnt == 0 and not eof_ok then
			if err == nil then
				return nil, 0, 'eof', false
			end
			return nil, 0, err, false
		end
		return ret_buf, cnt, err, not not found_term
	end)
end

function Stream:read_string_op(opts)
	local buf = LinearBuf.new()
	local ev  = self:read_into_op(buf, opts)

	return ev:wrap(function (ret_buf, cnt, err, complete)
		if not ret_buf then
			return nil, err, false
		end

		local s = ret_buf:tostring()

		if cnt == 0 and s == '' then
			if err == nil then
				return nil, 'eof', false
			end
			return nil, err, false
		end

		return s, err, not not complete
	end)
end

function Stream:read_some_op(max)
	assert(type(max) == 'number' and max >= 0, 'read_some_op: max must be non-negative')
	if max == 0 then return op.always('', nil) end

	return self:read_string_op { min = 1, max = max, eof_ok = true }
		:wrap(function (s, err)
			if err == 'eof' and not s then
				return nil, 'eof'
			end
			return s, err
		end)
end

function Stream:read_exactly_op(n)
	assert(type(n) == 'number' and n >= 0, 'read_exactly_op: n must be non-negative')
	if n == 0 then return op.always('', nil) end

	return self:read_string_op { min = n, max = n, eof_ok = false }
		:wrap(function (s, err)
			if err ~= nil then return nil, err end
			if not s or #s ~= n then return nil, 'short read' end
			return s, nil
		end)
end

function Stream:read_line_op(opts)
	assert(self.rx, 'stream is not readable')

	opts            = opts or {}
	local term      = opts.terminator or '\n'
	local keep_term = not not opts.keep_terminator
	local max_bytes = opts.max or math.huge

	local ev = self:read_string_op {
		min        = max_bytes,
		max        = max_bytes,
		terminator = term,
		eof_ok     = true,
	}

	return ev:wrap(function (s, err, complete)
		if err == 'closed' then
			return nil, 'closed', false
		end
		if not s then
			return nil, err, false
		end

		local is_complete = not not complete

		if not keep_term and #term > 0 and s:sub(- #term) == term then
			s = s:sub(1, - #term - 1)
		end

		return s, (err == 'eof') and nil or err, is_complete
	end)
end

function Stream:read_all_op()
	assert(self.rx, 'stream is not readable')

	local ev = self:read_string_op { min = math.huge, max = math.huge, eof_ok = true }

	return ev:wrap(function (s, err)
		-- Normalise EOF to success for read_all: EOF is the expected terminator.
		if err == 'eof' then err = nil end
		-- If no data at all, normalise to empty string.
		if not s then return '', err end
		return s, err
	end)
end

----------------------------------------------------------------------
-- Buffered write pump
----------------------------------------------------------------------

function Stream:_kick_pump()
	if self._pump_scheduled then return end
	if self._closed or not self.io then return end
	self._pump_scheduled = true
	sched():schedule(self._pump_task)
end

function Stream:_pump()
	self._pump_scheduled = false

	local io = self.io
	if self._closed or not io then
		return
	end
	if self._sticky_werr then
		return
	end
	if not (self.tx or self._big) then
		return
	end

	-- Cancel any prior wait; we are running now.
	self:_unlink_pump_wait()

	local progressed = false

	while true do
		if self._sticky_werr or self._closed or not self.io then
			break
		end

		local chunk
		if self._big then
			if self._big_off >= #self._big then
				self._big = nil
				self._big_off = 0
				notify_all(self, K_SPACE)
			else
				chunk = self._big:sub(self._big_off + 1)
			end
		elseif self.tx and self.tx:read_avail() > 0 then
			local avail = self.tx:read_avail()
			chunk = self.tx:peek(avail)
		else
			break
		end

		if not chunk or #chunk == 0 then
			break
		end

		local n, err, want = io:write_string(chunk)
		if err then
			self._sticky_werr = err
			notify_all(self, K_SPACE)
			notify_all(self, K_DRAIN)
			notify_all(self, K_TERM)
			break
		end

		if n == nil then
			-- Would block: arm pump on readiness.
			if want == 'rd' and io.on_readable then
				self._pump_token = io:on_readable(self._pump_task)
			else
				self._pump_token = io:on_writable(self._pump_task)
			end
			break
		end

		if n == 0 then
			-- No progress; avoid a busy loop.
			self._pump_token = io:on_writable(self._pump_task)
			break
		end

		progressed = true

		if self._big then
			self._big_off = self._big_off + n
			if self._big_off >= #self._big then
				self._big = nil
				self._big_off = 0
				notify_all(self, K_SPACE)
			end
		elseif self.tx then
			self.tx:advance_read(n)
			notify_all(self, K_SPACE)
		end
	end

	-- Drain notification.
	if (not self._big) and self.tx and self.tx:read_avail() == 0 then
		notify_all(self, K_DRAIN)
	end

	if progressed then
		notify_all(self, K_TERM) -- ensures blocked ops re-check promptly on progress
	end
end

----------------------------------------------------------------------
-- Buffered write ops
----------------------------------------------------------------------

function Stream:write_string_op(str)
	assert(self.tx, 'stream is not writable')
	assert(type(str) == 'string', 'write_string_op expects a string')

	local owner = {} -- identity for this op instance
	local have_lock = false
	local len = #str

	local function can_commit()
		if self._sticky_werr then return false, self._sticky_werr end
		if self._closed or not self.io then return false, 'closed' end
		if self._big then return false, K_SPACE end

		local cap = self.tx:capacity()

		if len <= self.tx:write_avail() then
			return true, 'ring'
		end

		-- Oversize allowed only when queue is empty.
		if self.tx:read_avail() == 0 and len > cap then
			return true, 'big'
		end

		return false, K_SPACE
	end

	local function acquire_lock()
		if have_lock then return true end
		if self._wr_owner == nil then
			self._wr_owner = owner
			have_lock = true
			return true
		end
		if self._wr_owner == owner then
			have_lock = true
			return true
		end
		return false
	end

	local function release_lock()
		if have_lock and self._wr_owner == owner then
			self._wr_owner = nil
			have_lock = false
			notify_one(self, K_WRGATE)
		end
	end

	local function make_commit(mode)
		return function ()
			if mode == 'ring' then
				self.tx:put(str)
			else
				-- big write: only when tx empty by can_commit policy
				self._big = str
				self._big_off = 0
			end

			-- Start or continue flushing in the background.
			self:_kick_pump()

			-- Release writer serialisation gate.
			release_lock()

			return len, nil
		end
	end

	local function probe_step()
		-- Avoid taking the lock unless we can complete immediately.
		if self._sticky_werr then return true, nil, self._sticky_werr end
		if self._closed or not self.io then return true, nil, 'closed' end

		if self._wr_owner ~= nil and self._wr_owner ~= owner then
			return false, K_WRGATE
		end

		local ok, mode_or = can_commit()
		if not ok then
			return false, mode_or
		end

		-- Ready: take lock (serialise) and complete.
		if not acquire_lock() then
			return false, K_WRGATE
		end

		return true, make_commit(mode_or)
	end

	local function run_step()
		if self._sticky_werr then return true, nil, self._sticky_werr end
		if self._closed or not self.io then return true, nil, 'closed' end

		if not acquire_lock() then
			return false, K_WRGATE
		end

		local ok, mode_or = can_commit()
		if not ok then
			if mode_or == K_SPACE then
				self:_kick_pump()
			end
			return false, mode_or
		end

		return true, make_commit(mode_or)
	end

	local function register(task, _, _, want)
		if want == K_WRGATE then
			return with_term_internal(self, task, K_WRGATE)
		end

		if want == K_SPACE or want == K_DRAIN then
			self:_kick_pump()
			return with_term_internal(self, task, want)
		end

		return with_term_internal(self, task, want or K_SPACE)
	end

	local function wrap(commit_or_nil, err)
		if not commit_or_nil then
			return nil, err
		end
		return commit_or_nil()
	end

	local ev = wait.waitable2(register, probe_step, run_step, wrap)

	return ev:on_abort(function ()
		release_lock()
	end)
end

function Stream:write_op(...)
	assert(self.tx, 'stream is not writable')

	local n = select('#', ...)
	if n == 0 then
		return op.always(0, nil)
	end

	local parts = {}
	for i = 1, n do
		local v = select(i, ...)
		parts[i] = (type(v) == 'string') and v or tostring(v)
	end
	return self:write_string_op(table.concat(parts))
end

function Stream:write_all_op(s)
	return self:write_string_op(s)
end

---@return Op
function Stream:flush_op()
	-- Read-only streams have nothing to flush.
	if not self.tx then
		return op.always(true, nil)
	end

	local function drained()
		return (not self._big) and (self.tx:read_avail() == 0)
	end

	local function probe_step()
		if self._sticky_werr then return true, nil, self._sticky_werr end
		if self._closed or not self.io then
			if drained() then return true, true, nil end
			return true, nil, 'closed'
		end
		if drained() then
			return true, true, nil
		end
		return false, K_DRAIN
	end

	local function run_step()
		if self._sticky_werr then return true, nil, self._sticky_werr end
		if self._closed or not self.io then
			if drained() then return true, true, nil end
			return true, nil, 'closed'
		end
		self:_kick_pump()
		if drained() then
			return true, true, nil
		end
		return false, K_DRAIN
	end

	local function register(task, _, _, want)
		if want == K_DRAIN then
			self:_kick_pump()
		end
		return with_term_internal(self, task, want or K_DRAIN)
	end

	local function wrap(ok, err)
		if ok then return true, nil end
		return nil, err
	end

	return wait.waitable2(register, probe_step, run_step, wrap)
end

----------------------------------------------------------------------
-- Misc
----------------------------------------------------------------------

function Stream:seek(whence, offset)
	if not (self.io and self.io.seek) then
		return nil, 'stream is not seekable'
	end
	whence = whence or 'cur'
	offset = offset or 0
	return self.io:seek(whence, offset)
end

function Stream:setvbuf(mode, _)
	if mode == 'no' then
		self.line_buffering = false
	elseif mode == 'line' then
		self.line_buffering = true
	elseif mode == 'full' then
		self.line_buffering = false
	else
		error('bad mode: ' .. tostring(mode))
	end
	return self
end

function Stream:filename()
	return self.io and self.io.filename
end

----------------------------------------------------------------------
-- Synchronous convenience wrappers
----------------------------------------------------------------------

function Stream:read_line(opts) return perform(self:read_line_op(opts)) end

function Stream:read_exactly(n) return perform(self:read_exactly_op(n)) end

function Stream:read_some(max) return perform(self:read_some_op(max)) end

function Stream:read_all() return perform(self:read_all_op()) end

function Stream:write(...) return perform(self:write_op(...)) end

function Stream:write_all(s) return perform(self:write_all_op(s)) end

function Stream:flush() return perform(self:flush_op()) end

return {
	open      = open,
	is_stream = is_stream,
	Stream    = Stream,
}

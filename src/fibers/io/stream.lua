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
---@field _closing boolean
---@field _sticky_rerr any|nil
---@field _sticky_werr any|nil
---@field _big string|nil
---@field _big_off integer
---@field _pump_task Task
---@field _pump_token WaitToken|nil
---@field _pump_scheduled boolean
---@field _rd_owner any|nil
---@field _wr_owner any|nil
local Stream = {}
Stream.__index = Stream

local DEFAULT_BUFFER_SIZE = 2 ^ 12
local BIG_WRITE_CHUNK     = 64 * 1024

-- Internal wait keys (not exposed).
local K_TERM   = 'term'
local K_SPACE  = 'space'
local K_DRAIN  = 'drain'
local K_RDGATE = 'rd_gate'
local K_WRGATE = 'wr_gate'

----------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------

local function sched()
	return runtime.current_scheduler
end

-- waitable2 wrap helper: allow steps to return a commit thunk (choice-safe).
-- If the first value is a function, it will be called to produce final results.
local function thunk_wrap(v1, ...)
	if type(v1) == 'function' then
		return v1(...)
	end
	return v1, ...
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

-- Shared waitable2 register helper.
--
-- Supports two modes:
--   * backend mode: wait on io:on_readable/on_writable (plus optional prime-once)
--   * internal-only mode: wait on internal waitset keys only (with default key)
--
-- opts:
--   internal          : set-like table of wants to treat as internal keys (e.g. {[K_RDGATE]=true})
--   internal_only     : boolean (if true, all wants are treated as internal keys)
--   default_internal  : key used when want is nil in internal_only mode
--   prime_once        : boolean (backend mode only): on first want==nil, schedule immediately
--   on_internal(key)  : optional callback invoked before registering internal key
local function make_waitable_register(self, opts)
	opts = opts or {}
	local internal = opts.internal or {}
	local primed = false

	return function (task, suspension, _, want)
		-- Internal-key path (explicit or forced internal-only).
		if opts.internal_only or internal[want] then
			local key = want
			if opts.internal_only and key == nil then
				key = opts.default_internal
			end
			if opts.on_internal then opts.on_internal(key) end
			return with_term_internal(self, task, key)
		end

		-- Backend path.
		local io = self.io
		if not io then
			suspension.sched:schedule(task)
			return with_term(self, task, NO_TOKEN)
		end

		if opts.prime_once and want == nil and not primed then
			primed = true
			suspension.sched:schedule(task)
			return with_term(self, task, NO_TOKEN)
		end

		if want == 'wr' and io.on_writable then
			return with_term(self, task, io:on_writable(task))
		end
		return with_term(self, task, io:on_readable(task))
	end
end

-- Generic gate helper (used for read/write serialisation).
-- field: stream field holding current owner token (e.g. '_rd_owner', '_wr_owner')
-- key: waitset key to notify on release (e.g. K_RDGATE, K_WRGATE)
local function make_gate(stream, field, key)
	local owner = {}
	local have  = false

	local function acquire()
		if have then return true end
		local cur = stream[field]
		if cur == nil or cur == owner then
			stream[field] = owner
			have = true
			return true
		end
		return false
	end

	local function release()
		if have and stream[field] == owner then
			stream[field] = nil
			have = false
			notify_one(stream, key)
		end
	end

	local function held_by_other()
		local cur = stream[field]
		return cur ~= nil and cur ~= owner
	end

	return { acquire = acquire, release = release, held_by_other = held_by_other }
end

local function broadcast(self)
	notify_all(self, K_TERM)
	notify_all(self, K_SPACE)
	notify_all(self, K_DRAIN)
	notify_all(self, K_RDGATE)
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
		_big_off        = 0,
		_pump_scheduled = false,
	}, Stream)

	if readable ~= false then s.rx = RingBuf.new(bufsize) end
	if writable ~= false then s.tx = RingBuf.new(bufsize) end

	s._pump_task = { run = function () s:_pump() end }
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

-- Begin closing the stream: wake any blocked operations promptly.
-- This does not tear down buffers or the backend; terminate() still does that.
function Stream:_begin_close(_)
	if self._closed then
		return broadcast(self)
	end
	if not self._closing then self._closing = true end
	return broadcast(self)
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
	self._closing = true
	self._rd_owner = nil
	self._wr_owner = nil
	self:_unlink_pump_wait()

	local io = self.io
	self.io = nil

	self.rx, self.tx = nil, nil
	self._big, self._big_off = nil, 0

	if io and io.close then
		pcall(function () io:close() end)
	end

	return broadcast(self)
end

---@return Op
function Stream:close_op()
	-- Mark closing immediately so blocked ops wake and observe closure promptly.
	-- Still attempt a graceful flush on writable streams.
	self:_begin_close('closing')

	-- Idempotence: if already terminated, close succeeds.
	if self._closed then
		return op.always(true, nil)
	end

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
		if ok == nil then return nil, err end
		return true, nil
	end)
end

----------------------------------------------------------------------
-- Read path
----------------------------------------------------------------------

---@param stream Stream
---@param buf any
---@param min integer
---@param max integer
---@param terminator string|nil
---@return fun(): boolean, ...  -- probe_step()
---@return fun(): boolean, ...  -- run_step()
local function make_read_steps(stream, buf, min, max, terminator)
	local tally = 0
	local term_target = nil
	local want_hint = nil

	local function term_enabled()
		return terminator ~= nil and terminator ~= ''
	end

	local function maybe_clamp()
		if term_target or not term_enabled() or not stream.rx then return end
		local loc = stream.rx:find(terminator)
		if not loc then return end
		local final = tally + loc + #terminator
		if final <= max then
			term_target = final
			min, max = final, final
		end
	end

	local function done(err)
		want_hint = nil
		return true, buf, tally, err
	end

	local function done_thunk(err, drain_fn)
		return true, function ()
			if drain_fn then drain_fn() end
			want_hint = nil
			return buf, tally, err
		end
	end

	local function drain_once()
		if not stream.rx then return end
		local avail = stream.rx:read_avail()
		if avail <= 0 or tally >= max then return end
		local need = math.min(avail, max - tally)
		if need <= 0 then return end
		local chunk = stream.rx:take(need)
		if chunk and #chunk > 0 then
			buf:append(chunk)
			tally = tally + #chunk
		end
	end

	local function drain_all()
		if not stream.rx then return end
		while tally < max do
			local before = tally
			drain_once()
			if tally == before then break end
		end
	end

	-- Terminal checks that do not perform backend IO.
	-- IMPORTANT: probe_step must be non-destructive under op.choice.
	-- Any draining from rx must happen only in a commit thunk.
	local function terminal_noio_probe()
		if stream._sticky_rerr then
			-- Choice-safe: do not drain here; drain in commit thunk.
			maybe_clamp()
			return done_thunk(stream._sticky_rerr, drain_all)
		end
		if stream._closed or stream._closing or not stream.io then
			return done('closed')
		end
		if not stream.rx then
			return done('not readable')
		end
		return nil
	end

	local function terminal_noio_run()
		if stream._sticky_rerr then
			maybe_clamp()
			drain_all()
			return done(stream._sticky_rerr)
		end
		if stream._closed or stream._closing or not stream.io then return done('closed') end
		if not stream.rx then return done('not readable') end
		return nil
	end

	-- Probe step:
	--   * must not call io:read_string(...)
	--   * must be non-destructive under op.choice
	local function probe_step()
		local ok, a, b, c = terminal_noio_probe()
		if ok then return ok, a, b, c end

		maybe_clamp()
		if tally >= min then return done(nil) end

		-- Choice-safe fast path: if rx already contains enough bytes to
		-- satisfy min (after any terminator clamp), return a commit thunk
		-- that performs the drain.
		local rx = stream.rx
		if rx and tally < max then
			local avail = rx:read_avail()
			if avail > 0 then
				local possible = tally + math.min(avail, max - tally)
				if possible >= min then
					return done_thunk(nil, drain_once)
				end
			end
		end

		return false, want_hint
	end

	-- Run step:
	--   * may call backend IO
	--   * returns false,want when it would block
	local function run_step()
		while true do
			local ok, b, n, e = terminal_noio_run()
			if ok then return ok, b, n, e end

			maybe_clamp()

			drain_once()
			if tally >= min then return done(nil) end

			local io = stream.io
			if not (io and io.read_string) then
				return done('backend does not support read_string')
			end

			local room = stream.rx:write_avail()
			if room <= 0 then
				return done('buffer capacity exhausted')
			end

			local data, err, want = io:read_string(room)
			if err ~= nil then
				stream._sticky_rerr = err
				return done(err)
			end

			if data == nil then
				want_hint = want
				return false, want
			end

			if data == '' then
				-- EOF
				return done(nil)
			end

			stream.rx:put(data)
		end
	end

	return probe_step, run_step
end

---@param buf LinearBuf
---@param opts? { min?: integer, max?: integer, terminator?: string, eof_ok?: boolean }
---@return Op
function Stream:read_into_op(buf, opts)
	assert(self.rx, 'stream is not readable')

	opts             = opts or {}
	local min        = opts.min or 1
	local max        = opts.max or min
	local terminator = opts.terminator
	local eof_ok     = not not opts.eof_ok

	local probe_step, run_step = make_read_steps(self, buf, min, max, terminator)

	-- Read gate: allow only one in-flight read op at a time.
	local gate = make_gate(self, '_rd_owner', K_RDGATE)

	local function gate_step(step_fn)
		return function (...)
			-- If another read op owns the gate, wait on K_RDGATE.
			if not gate.acquire() then
				return false, K_RDGATE
			end
			return step_fn(...)
		end
	end

	probe_step = gate_step(probe_step)
	run_step   = gate_step(run_step)

	local register = make_waitable_register(self, { internal = { [K_RDGATE] = true }, prime_once = true })

	-- Ensure the read gate is released on completion; choice abort releases via on_abort.
	local function read_wrap(v1, ...)
		local ret_buf, cnt, err = thunk_wrap(v1, ...)
		gate.release()
		return ret_buf, cnt, err
	end

	local ev = wait.waitable2(register, probe_step, run_step, read_wrap)
	ev = ev:on_abort(function ()
		gate.release()
	end)

	return ev:wrap(function (ret_buf, cnt, err)
		if cnt == 0 and not eof_ok then
			return nil, 0, err
		end
		return ret_buf, cnt, err
	end)
end

---@param opts? { min?: integer, max?: integer, terminator?: string, eof_ok?: boolean }
---@return Op  -- when performed: s:string|nil, cnt:integer, err:any|nil
function Stream:read_string_op(opts)
	local buf = LinearBuf.new()
	local ev  = self:read_into_op(buf, opts)

	return ev:wrap(function (ret_buf, cnt, err)
		if not ret_buf then return nil, 0, err end

		local s = ret_buf:tostring()
		if cnt == 0 and s == '' then
			-- EOF before any bytes: nil (Lua style)
			return nil, 0, err
		end
		return s, cnt, err
	end)
end

---@param max integer
---@return Op  -- when performed: s:string|nil, err:any|nil
function Stream:read_some_op(max)
	assert(type(max) == 'number' and max >= 0, 'read_some_op: max must be non-negative')
	if max == 0 then return op.always('', nil) end

	return self:read_string_op { min = 1, max = max, eof_ok = true }
		:wrap(function (s, cnt, err)
			if err ~= nil then return nil, err end
			if not s or cnt == 0 then return nil, nil end
			return s, nil
		end)
end

---@param n integer
---@return Op  -- when performed: s:string|nil, err:any|nil
function Stream:read_exactly_op(n)
	assert(type(n) == 'number' and n >= 0, 'read_exactly_op: n must be non-negative')
	if n == 0 then return op.always('', nil) end

	return self:read_string_op { min = n, max = n, eof_ok = false }
		:wrap(function (s, cnt, err)
			if err ~= nil then return nil, err end
			if not s or cnt ~= n then return nil, 'short read' end
			return s, nil
		end)
end

---@param opts? { terminator?: string, keep_terminator?: boolean }
---@return Op  -- when performed: line:string|nil, err:any|nil
function Stream:read_line_op(opts)
	assert(self.rx, 'stream is not readable')

	opts            = opts or {}
	local term      = opts.terminator or '\n'
	local keep_term = not not opts.keep_terminator

	-- Newline-or-EOF: clamp on terminator when present; otherwise read until EOF.
	local ev = self:read_string_op {
		min        = math.huge,
		max        = math.huge,
		terminator = term,
		eof_ok     = true,
	}

	return ev:wrap(function (s, cnt, err)
		if err ~= nil then return nil, err end
		if not s or cnt == 0 then return nil, nil end

		if not keep_term and #term > 0 and s:sub(- #term) == term then
			s = s:sub(1, - #term - 1)
		end

		return s, nil
	end)
end

---@return Op  -- when performed: data:string, err:any|nil
function Stream:read_all_op()
	assert(self.rx, 'stream is not readable')

	return self:read_string_op { min = math.huge, max = math.huge, eof_ok = true }
		:wrap(function (s, _, err)
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

local function next_write_chunk(self)
	if self._big then
		if self._big_off >= #self._big then
			self._big = nil
			self._big_off = 0
			notify_all(self, K_SPACE)
			return nil
		end
		local remaining = #self._big - self._big_off
		local take = remaining
		if take > BIG_WRITE_CHUNK then take = BIG_WRITE_CHUNK end
		return self._big:sub(self._big_off + 1, self._big_off + take), 'big'
	end

	if self.tx and self.tx:read_avail() > 0 then
		local avail = self.tx:read_avail()
		if avail > BIG_WRITE_CHUNK then avail = BIG_WRITE_CHUNK end
		return self.tx:peek(avail), 'ring'
	end

	return nil
end

local function advance_after_write(self, mode, n)
	if mode == 'big' then
		self._big_off = self._big_off + n
		if self._big_off >= #self._big then
			self._big = nil
			self._big_off = 0
			notify_all(self, K_SPACE)
		end
		return
	end

	self.tx:advance_read(n)
	notify_all(self, K_SPACE)
end

function Stream:_pump()
	self._pump_scheduled = false

	local io = self.io
	if self._closed or not io then return end
	if self._sticky_werr then return end
	if not (self.tx or self._big) then return end

	self:_unlink_pump_wait()

	local progressed = false

	while true do
		if self._sticky_werr or self._closed or not self.io then break end

		local chunk, mode = next_write_chunk(self)
		if not chunk or #chunk == 0 then break end

		local n, err, want = io:write_string(chunk)
		if err then
			self._sticky_werr = err
			broadcast(self) -- wakes space/drain/term/wr_gate
			break
		end

		if n == nil then
			if want == 'rd' and io.on_readable then
				self._pump_token = io:on_readable(self._pump_task)
			else
				self._pump_token = io:on_writable(self._pump_task)
			end
			break
		end

		if n == 0 then
			self._pump_token = io:on_writable(self._pump_task)
			break
		end

		progressed = true
		advance_after_write(self, mode, n)
	end

	if (not self._big) and self.tx and self.tx:read_avail() == 0 then
		notify_all(self, K_DRAIN)
	end
	if progressed then
		notify_all(self, K_TERM)
	end
end

----------------------------------------------------------------------
-- Buffered write ops
----------------------------------------------------------------------

---@param str string
---@return Op  -- when performed: bytes_written:integer|nil, err:any|nil
function Stream:write_string_op(str)
	assert(self.tx, 'stream is not writable')
	assert(type(str) == 'string', 'write_string_op expects a string')

	local gate = make_gate(self, '_wr_owner', K_WRGATE)
	local len = #str

	local function can_commit()
		if self._sticky_werr then return false, self._sticky_werr end
		if self._closed or self._closing or not self.io then return false, 'closed' end
		if self._big then return false, K_SPACE end

		local cap = self.tx:capacity()
		if len <= self.tx:write_avail() then
			return true, 'ring'
		end

		if self.tx:read_avail() == 0 and len > cap then
			return true, 'big'
		end

		return false, K_SPACE
	end

	local function make_commit(mode)
		return function ()
			if mode == 'ring' then
				self.tx:put(str)
			else
				self._big = str
				self._big_off = 0
			end

			self:_kick_pump()
			gate.release()
			return len, nil
		end
	end

	local function step(is_probe)
		if self._sticky_werr then return true, nil, self._sticky_werr end
		if self._closed or self._closing or not self.io then return true, nil, 'closed' end

		if gate.held_by_other() then
			return false, K_WRGATE
		end

		local ok, mode_or = can_commit()
		if not ok then
			if not is_probe and mode_or == K_SPACE then
				self:_kick_pump()
			end
			return false, mode_or
		end

		-- Probe: only take the gate if we can complete immediately.
		if not gate.acquire() then
			return false, K_WRGATE
		end

		-- Run: we already ensured commit is possible; probe uses same path.
		return true, make_commit(mode_or)
	end

	local function probe_step() return step(true) end
	local function run_step() return step(false) end

	local register = make_waitable_register(self, {
		internal_only = true, default_internal = K_SPACE,
		on_internal = function (key) if key == K_SPACE or key == K_DRAIN then self:_kick_pump() end end,
	})

	local function wrap(commit_or_nil, err)
		if not commit_or_nil then
			gate.release()
			return nil, err
		end
		return commit_or_nil()
	end

	local ev = wait.waitable2(register, probe_step, run_step, wrap)
	return ev:on_abort(function () gate.release() end)
end

---@param ... any
---@return Op  -- when performed: bytes_written:integer|nil, err:any|nil
function Stream:write_op(...)
	assert(self.tx, 'stream is not writable')

	local n = select('#', ...)
	if n == 0 then return op.always(0, nil) end

	local parts = {}
	for i = 1, n do
		local v = select(i, ...)
		parts[i] = (type(v) == 'string') and v or tostring(v)
	end
	return self:write_string_op(table.concat(parts))
end

---@param s string
---@return Op
function Stream:write_all_op(s)
	return self:write_string_op(s)
end

---@return Op  -- when performed: ok:boolean|nil, err:any|nil
function Stream:flush_op()
	if not self.tx then
		return op.always(true, nil)
	end

	-- Write gate: serialise flush with concurrent writers.
	local gate = make_gate(self, '_wr_owner', K_WRGATE)

	local function drained()
		return (not self._big) and (self.tx:read_avail() == 0)
	end

	local function step(is_probe)
		if self._sticky_werr then return true, nil, self._sticky_werr end
		if self._closed or not self.io then
			if drained() then return true, true, nil end
			return true, nil, 'closed'
		end

		-- If another writer/flush owns the gate, wait for it.
		if not gate.acquire() then
			return false, K_WRGATE
		end

		if drained() then return true, true, nil end
		if not is_probe then
			self:_kick_pump()
		end

		return false, K_DRAIN
	end

	local function probe_step() return step(true) end
	local function run_step() return step(false) end

	local register = make_waitable_register(self, {
		internal_only = true, default_internal = K_DRAIN,
		on_internal = function (key) if key == K_DRAIN then self:_kick_pump() end end,
	})

	local function wrap(ok, err)
		gate.release()
		if ok then return true, nil end
		return nil, err
	end

	local ev = wait.waitable2(register, probe_step, run_step, wrap)
	return ev:on_abort(function ()
		gate.release()
	end)
end

----------------------------------------------------------------------
-- Misc
----------------------------------------------------------------------

function Stream:seek(whence, offset)
	self:flush()
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

function Stream:close() return perform(self:close_op()) end

----------------------------------------------------------------------
-- Lua io-like compatibility (legacy return shapes)
----------------------------------------------------------------------

---@param fmt? string|integer
---@return Op  -- when performed: value|nil, err:any|nil
function Stream:read_op(fmt)
	assert(self.rx, 'stream is not readable')

	if fmt == nil or fmt == '*l' then return self:read_line_op() end
	if fmt == '*L' then return self:read_line_op { keep_terminator = true } end
	if fmt == '*a' then return self:read_all_op() end

	if type(fmt) == 'number' then
		assert(fmt >= 0, 'read_op: n must be non-negative')
		if fmt == 0 then return op.always('', nil) end

		return self:read_string_op { min = 1, max = fmt, eof_ok = true }
			:wrap(function (s, cnt, err)
				if err then return nil, err end
				if not s or cnt == 0 then return nil, nil end
				return s, nil
			end)
	end

	error('read_op: invalid format ' .. tostring(fmt))
end

function Stream:read(fmt)
	return perform(self:read_op(fmt))
end

return {
	open      = open,
	is_stream = is_stream,
	Stream    = Stream,
}

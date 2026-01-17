---@module 'fibers.io.stream'

local wait    = require 'fibers.wait'
local bytes   = require 'fibers.utils.bytes'
local op      = require 'fibers.op'
local runtime = require 'fibers.runtime'
local perform = require 'fibers.performer'.perform

local RingBuf   = bytes.RingBuf
local LinearBuf = bytes.LinearBuf

local unpack = rawget(table, 'unpack') or _G.unpack
local pack   = rawget(table, 'pack') or function (...)
	return { n = select('#', ...), ... }
end

local DEFAULT_BUF = 2 ^ 12
local CHUNK_IN    = 4096
local CHUNK_OUT   = 4096

-- Stream-local waitset keys
local K_TERM   = 'term'
local K_RDGATE = 'rd_gate'
local K_WRGATE = 'wr_gate'
local K_SPACE  = 'space'
local K_DRAIN  = 'drain'

---@class StreamBackend
---@field read_string fun(self: any, max: integer): string|nil, any|nil, any|nil
---@field write_string fun(self: any, data: string): integer|nil, any|nil, any|nil
---@field on_readable fun(self: any, task: Task): WaitToken
---@field on_writable fun(self: any, task: Task): WaitToken
---@field close fun(self: any): boolean|nil, any|nil
---@field seek fun(self: any, whence: any, offset: integer): integer|nil, any|nil
---@field filename string|nil
---@field fileno fun(self: any): integer|nil

---@class Stream
---@field io StreamBackend|nil
---@field rx RingBuf|nil
---@field tx RingBuf|nil
---@field pb string[]|nil
---@field eof boolean
---@field rd_err any|nil
---@field wr_err any|nil
---@field closing boolean
---@field closed boolean
---@field terminated any|nil
---@field bufmode '"no"'|'"line"'|'"full"'
---@field line_buffering boolean
---@field _ws Waitset
---@field _rd_owner any|nil
---@field _wr_owner any|nil
---@field _tx_big { s: string, off: integer }|nil
---@field _pump Task
---@field _pump_wait WaitToken|nil
---@field _pump_scheduled boolean
local Stream = {}
Stream.__index = Stream

local function sched()
	return runtime.current_scheduler
end

local function ws_token2(t1, t2)
	return {
		unlink = function ()
			if t1 and t1.unlink then t1:unlink() end
			if t2 and t2.unlink then t2:unlink() end
		end
	}
end

local function ws_notify_one(self, key)
	self._ws:notify_one(key, sched())
end

local function ws_notify_all(self, key)
	self._ws:notify_all(key, sched())
end

local function pb_len(pb)
	if not pb then return 0 end
	local n = 0
	for i = 1, #pb do n = n + #pb[i] end
	return n
end

local function pb_take(self, n)
	local pb = self.pb
	if not pb or n <= 0 then return '' end
	local out = {}
	while n > 0 and #pb > 0 do
		local s = pb[1]
		if #s <= n then
			out[#out + 1] = s
			table.remove(pb, 1)
			n = n - #s
		else
			out[#out + 1] = s:sub(1, n)
			pb[1] = s:sub(n + 1)
			n = 0
		end
	end
	if #pb == 0 then self.pb = nil end
	return table.concat(out)
end

local function take_n(self, n)
	if n <= 0 then return '' end
	local a = pb_len(self.pb)
	if a > 0 then
		local x = pb_take(self, math.min(n, a))
		n = n - #x
		if n <= 0 then return x end
		return x .. self.rx:take(n)
	end
	return self.rx:take(n)
end

local function peek_prefix(self, maxn)
	maxn = maxn or math.huge
	local out = {}
	local n = 0

	local pb = self.pb
	if pb then
		for i = 1, #pb do
			if n >= maxn then break end
			local s = pb[i]
			local want = math.min(#s, maxn - n)
			out[#out + 1] = (want == #s) and s or s:sub(1, want)
			n = n + want
		end
	end

	if n < maxn then
		local rx = self.rx
		if rx and rx.peek then
			local want = math.min(rx:read_avail(), maxn - n)
			if want > 0 then
				out[#out + 1] = rx:peek(want)
			end
		end
	end

	return table.concat(out)
end

local function term_err(self)
	if self.terminated ~= nil then return self.terminated end
	if self.closed or self.io == nil then return 'closed' end
	return nil
end

function Stream:_arm_term(task)
	return self._ws:add(K_TERM, task)
end

function Stream:_reg_readable(task)
	local io = self.io
	if not io then
		sched():schedule(task)
		return self:_arm_term(task)
	end
	return ws_token2(io:on_readable(task), self:_arm_term(task))
end

function Stream:_reg_writable(task)
	local io = self.io
	if not io then
		sched():schedule(task)
		return self:_arm_term(task)
	end
	return ws_token2(io:on_writable(task), self:_arm_term(task))
end

function Stream:_acquire_rd(owner)
	if self._rd_owner and self._rd_owner ~= owner then return false end
	self._rd_owner = owner
	return true
end

function Stream:_release_rd(owner)
	if self._rd_owner == owner then
		self._rd_owner = nil
		ws_notify_one(self, K_RDGATE)
	end
end

function Stream:_acquire_wr(owner)
	if self._wr_owner and self._wr_owner ~= owner then return false end
	self._wr_owner = owner
	return true
end

function Stream:_release_wr(owner)
	if self._wr_owner == owner then
		self._wr_owner = nil
		ws_notify_one(self, K_WRGATE)
	end
end

----------------------------------------------------------------------
-- Output pump: flush committed tx/tx_big to backend
----------------------------------------------------------------------

function Stream:_stop_pump_wait()
	if self._pump_wait and self._pump_wait.unlink then
		self._pump_wait:unlink()
	end
	self._pump_wait = nil
end

function Stream:_kick_pump()
	if self._pump_scheduled then return end
	self._pump_scheduled = true
	sched():schedule(self._pump)
end

function Stream:_pump_once()
	if self.terminated ~= nil or self.closed or self.wr_err ~= nil then
		self:_stop_pump_wait()
		return true
	end

	local io = self.io
	if not (io and io.write_string) then
		self.wr_err = self.wr_err or 'backend missing write_string'
		self:terminate(self.wr_err)
		return true
	end

	local chunk
	if self._tx_big then
		local s, off = self._tx_big.s, self._tx_big.off
		if off >= #s then
			self._tx_big = nil
			ws_notify_all(self, K_DRAIN)
			ws_notify_all(self, K_SPACE)
			return true
		end
		chunk = s:sub(off + 1, math.min(#s, off + CHUNK_OUT))
	elseif self.tx and self.tx:read_avail() > 0 then
		assert(self.tx.peek, 'ring buffer must implement peek() for tx')
		chunk = self.tx:peek(math.min(self.tx:read_avail(), CHUNK_OUT))
	else
		self:_stop_pump_wait()
		ws_notify_all(self, K_DRAIN)
		ws_notify_all(self, K_SPACE)
		return true
	end

	local n, err, want = io:write_string(chunk)

	if n and n > 0 then
		if self._tx_big then
			self._tx_big.off = self._tx_big.off + n
			if self._tx_big.off >= #self._tx_big.s then
				self._tx_big = nil
				ws_notify_all(self, K_DRAIN)
			end
		else
			self.tx:take(n)
			if self.tx:read_avail() == 0 then ws_notify_all(self, K_DRAIN) end
		end
		ws_notify_one(self, K_SPACE)
		return false
	end

	-- would-block (or backend explicitly asked for wr)
	if (n == nil and err == nil) or want == 'wr' or n == 0 then
		if not self._pump_wait then
			self._pump_wait = self:_reg_writable(self._pump)
		end
		return true
	end

	-- hard error
	self.wr_err = self.wr_err or err or 'write failed'
	self:terminate(self.wr_err)
	return true
end

function Stream:_pump_run()
	self._pump_scheduled = false
	for _ = 1, 8 do
		local done = self:_pump_once()
		if done then return end
	end
	self:_kick_pump()
end

----------------------------------------------------------------------
-- Core read op (choice-safe, want-aware)
----------------------------------------------------------------------

-- Returns on perform:
--   s|nil, err|nil, complete:boolean
function Stream:read_bytes_op(opts)
	assert(self.rx, 'stream is not readable')
	opts = opts or {}

	local want_min  = opts.want_min or 1
	local want_max  = opts.want_max or want_min
	local term      = opts.term
	local keep_term = not not opts.keep_term
	local max_bytes = opts.max_bytes or math.huge
	local eof_ok    = not not opts.eof_ok

	local owner = {}
	local owned = false

	local function buffered_avail()
		return pb_len(self.pb) + self.rx:read_avail()
	end

	local function decide_from_buffer()
		local avail = buffered_avail()
		if avail <= 0 then return nil end

		if term then
			local scan = peek_prefix(self, math.min(avail, max_bytes + #term))
			local i, j = scan:find(term, 1, true)
			if i then
				local take = keep_term and j or (i - 1)
				local drop = j
				return take, drop, true
			end
			if #scan > max_bytes then
				return 'line_too_long'
			end
			return nil
		end

		local n = math.min(avail, want_max)
		if n >= want_min then
			return n, n, true
		end
		return nil
	end

	local function register(task, _, _, want)
		-- external readiness wants
		if want == 'rd' then return self:_reg_readable(task) end
		if want == 'wr' then return self:_reg_writable(task) end
		if want == 'any' then return ws_token2(self:_reg_readable(task), self:_reg_writable(task)) end
		-- internal keys
		return self._ws:add(want or K_TERM, task)
	end

	local function probe_step()
		local terr = term_err(self)
		if terr then
			return true, function () return nil, terr, false end
		end
		if self.rd_err and buffered_avail() == 0 then
			return true, function () return nil, self.rd_err, false end
		end
		if self.eof and buffered_avail() == 0 then
			return true, function () return nil, 'eof', false end
		end

		local d = decide_from_buffer()
		if d == 'line_too_long' then
			return true, function () return nil, 'line_too_long', false end
		end
		if d then
			-- consumption is safe without acquiring the read gate because no backend read is needed
			local _, drop, complete = d, select(2, d), select(3, d)
			return true, function ()
				local s = take_n(self, drop)
				if (not keep_term) and term and #term > 0 and s:sub(- #term) == term then
					s = s:sub(1, - #term - 1)
				end
				return s, nil, complete
			end
		end

		-- need more bytes: if a reader is already doing backend reads, wait on gate;
		-- otherwise wait for backend readiness (default 'rd' unless backend says otherwise later).
		if self._rd_owner ~= nil and self._rd_owner ~= owner then
			return false, K_RDGATE
		end
		return false, 'rd'
	end

	local function run_step()
		local terr = term_err(self)
		if terr then
			return true, function ()
				if owned then self:_release_rd(owner) end
				return nil, terr, false
			end
		end

		local d = decide_from_buffer()
		if d == 'line_too_long' then
			return true, function ()
				if owned then self:_release_rd(owner) end
				return nil, 'line_too_long', false
			end
		end
		if d then
			local _, drop, complete = d, select(2, d), select(3, d)
			return true, function ()
				local s = take_n(self, drop)
				if owned then self:_release_rd(owner) end
				if (not keep_term) and term and #term > 0 and s:sub(- #term) == term then
					s = s:sub(1, - #term - 1)
				end
				return s, nil, complete
			end
		end

		-- backend read required: serialise backend reads with the read gate
		if not owned then
			if not self:_acquire_rd(owner) then
				return false, K_RDGATE
			end
			owned = true
		end

		if self.rd_err and buffered_avail() == 0 then
			return true, function ()
				self:_release_rd(owner)
				return nil, self.rd_err, false
			end
		end
		if self.eof and buffered_avail() == 0 then
			return true, function ()
				self:_release_rd(owner)
				return nil, 'eof', false
			end
		end

		local io = self.io
		if not (io and io.read_string) then
			self.rd_err = self.rd_err or 'backend missing read_string'
			return true, function ()
				self:_release_rd(owner)
				return nil, self.rd_err, false
			end
		end

		local room = self.rx:write_avail()
		if room <= 0 then
			-- no space to read more; allow eof_ok to return whatever is buffered
			if eof_ok and buffered_avail() > 0 then
				return true, function ()
					local s = take_n(self, math.min(buffered_avail(), want_max))
					self:_release_rd(owner)
					return s, nil, false
				end
			end
			return true, function ()
				self:_release_rd(owner)
				return nil, 'buffer_full', false
			end
		end

		local data, err, want = io:read_string(math.min(room, CHUNK_IN))

		if data and #data > 0 then
			self.rx:put(data)
			return false -- progress; task will be rescheduled by waitable2 machinery
		end

		-- EOF
		if data == '' and err == nil then
			self.eof = true
			if eof_ok and buffered_avail() > 0 then
				return true, function ()
					local s = take_n(self, math.min(buffered_avail(), want_max))
					self:_release_rd(owner)
					return s, nil, false
				end
			end
			return true, function ()
				self:_release_rd(owner)
				return nil, 'eof', false
			end
		end

		-- would-block: propagate want (default 'rd')
		if data == nil and err == nil then
			return false, want or 'rd'
		end

		-- hard error
		self.rd_err = self.rd_err or err or 'read failed'
		return true, function ()
			self:_release_rd(owner)
			return nil, self.rd_err, false
		end
	end

	local function wrap_fn(commit)
		return commit()
	end

	local ev = wait.waitable2(register, probe_step, run_step, wrap_fn)

	return ev:on_abort(function ()
		if owned then self:_release_rd(owner) end
	end)
end

function Stream:read_some_op(max)
	max = max or 4096
	if max <= 0 then return op.always('', nil) end
	return self:read_bytes_op { want_min = 1, want_max = max, eof_ok = true }
		:wrap(function (s, err)
			if s then return s, nil end
			return nil, err
		end)
end

function Stream:read_line_op(opts)
	opts       = opts or {}
	local term = opts.terminator or '\n'
	local keep = not not opts.keep_terminator
	local max  = opts.max or 65536

	return self:read_bytes_op { term = term, keep_term = keep, max_bytes = max, eof_ok = true }
		:wrap(function (s, err, complete)
			return s, err, complete
		end)
end

-- Exact: returns s,nil on success; nil,err,partial? on short/EOF
function Stream:read_exactly_op(n)
	assert(type(n) == 'number' and n >= 0, 'read_exactly_op: n must be non-negative')
	if n == 0 then return op.always('', nil) end

	-- Implement via repeated read_some_op under a single waitable2 so it is choice-safe.
	-- We consume from buffers/backend and roll back via pushback on abort.
	local owner  = {}
	local owned  = false
	local buf    = LinearBuf.new()
	local staged = {}
	local have   = 0

	local function stage_restore()
		if #staged == 0 then return end
		local pb = self.pb or {}
		local new = {}
		for i = 1, #staged do new[#new + 1] = staged[i] end
		for i = 1, #pb do new[#new + 1] = pb[i] end
		self.pb = new
		staged = {}
	end

	local function register(task, _, _, want)
		if want == 'rd' then return self:_reg_readable(task) end
		if want == 'wr' then return self:_reg_writable(task) end
		if want == 'any' then return ws_token2(self:_reg_readable(task), self:_reg_writable(task)) end
		return self._ws:add(want or K_TERM, task)
	end

	local function probe_step()
		if term_err(self) then
			return true, function () return nil, term_err(self) end
		end
		-- force run path (no consumption in probe)
		if self._rd_owner ~= nil and self._rd_owner ~= owner then
			return false, K_RDGATE
		end
		return false, 'rd'
	end

	local function run_step()
		local terr = term_err(self)
		if terr then
			return true, function ()
				if owned then self:_release_rd(owner) end
				return nil, terr
			end
		end

		if not owned then
			if not self:_acquire_rd(owner) then
				return false, K_RDGATE
			end
			owned = true
		end

		while have < n do
			local avail = pb_len(self.pb) + self.rx:read_avail()
			if avail > 0 then
				local take = math.min(avail, n - have, 4096)
				local s = take_n(self, take)
				staged[#staged + 1] = s
				buf:append(s)
				have = have + #s
			else
				if self.eof then
					return true, function ()
						local partial = buf:tostring()
						self:_release_rd(owner)
						return nil, 'eof', (partial ~= '' and partial or nil)
					end
				end
				if self.rd_err then
					return true, function ()
						self:_release_rd(owner)
						return nil, self.rd_err
					end
				end

				local io = self.io
				if not (io and io.read_string) then
					self.rd_err = self.rd_err or 'backend missing read_string'
					return true, function ()
						self:_release_rd(owner)
						return nil, self.rd_err
					end
				end

				local data, err, want = io:read_string(math.min(CHUNK_IN, n - have))
				if data and #data > 0 then
					staged[#staged + 1] = data
					buf:append(data)
					have = have + #data
				elseif data == '' and err == nil then
					self.eof = true
				elseif data == nil and err == nil then
					return false, want or 'rd'
				else
					self.rd_err = self.rd_err or err or 'read failed'
				end
			end
		end

		return true, function ()
			local s = buf:tostring()
			self:_release_rd(owner)
			return s, nil
		end
	end

	local function wrap_fn(commit)
		return commit()
	end

	local ev = wait.waitable2(register, probe_step, run_step, wrap_fn)

	return ev:on_abort(function ()
		if owned then
			stage_restore()
			self:_release_rd(owner)
		end
	end)
end

function Stream:read_all_op(limit)
	limit = limit or math.huge
	local buf = LinearBuf.new()
	local have = 0

	return op.guard(function ()
		return self:read_some_op(4096):or_else(function ()
			-- not used; keep this op non-blocking only when read_some is ready
			return nil, 'internal'
		end)
	end):wrap(function ()
		-- Fallback implementation: loop in fibre space (still scope-aware),
		-- using read_some_op until EOF/error.
		while true do
			local s, err = perform(self:read_some_op(4096))
			if s then
				buf:append(s)
				have = have + #s
				if have > limit then
					return buf:tostring(), 'limit_exceeded'
				end
			else
				if err == 'eof' then
					return buf:tostring(), nil
				end
				return buf:tostring(), err
			end
		end
	end)
end

----------------------------------------------------------------------
-- Writes (choice-atomic) + flush + close
----------------------------------------------------------------------

local function rb_cap(rb)
	if rb.capacity then return rb:capacity() end
	return (rb:read_avail() + rb:write_avail())
end

function Stream:write_bytes_op(str)
	assert(self.tx, 'stream is not writable')
	assert(type(str) == 'string', 'write expects string')
	if #str == 0 then return op.always(0, nil) end

	local owner = {}
	local owned = false
	local len   = #str

	local function can_enqueue()
		if self._tx_big then return false end
		local used = self.tx:read_avail()
		local free = self.tx:write_avail()
		local cap  = rb_cap(self.tx)

		if len <= free then return true end
		-- oversize allowed only when queue empty
		if used == 0 and len > cap then return true end
		return false
	end

	local function register(task, _, _, want)
		if want == K_WRGATE then return self._ws:add(K_WRGATE, task) end
		if want == K_SPACE then return self._ws:add(K_SPACE, task) end
		return self._ws:add(K_TERM, task)
	end

	local function probe_step()
		local terr = term_err(self)
		if terr then
			return true, function () return nil, terr end
		end
		if self.wr_err then
			return true, function () return nil, self.wr_err end
		end
		if self.closing then
			return true, function () return nil, 'closed' end
		end

		if self._wr_owner ~= nil and self._wr_owner ~= owner then
			return false, K_WRGATE
		end
		if not can_enqueue() then
			return false, K_SPACE
		end

		return true, function ()
			if self.closing or self.terminated ~= nil or self.wr_err then
				return nil, 'closed'
			end
			if self.tx:read_avail() == 0 and len > rb_cap(self.tx) then
				self._tx_big = { s = str, off = 0 }
			else
				self.tx:put(str)
			end
			self:_kick_pump()
			return len, nil
		end
	end

	local function run_step()
		local terr = term_err(self)
		if terr then
			return true, function ()
				if owned then self:_release_wr(owner) end
				return nil, terr
			end
		end
		if self.wr_err then
			return true, function ()
				if owned then self:_release_wr(owner) end
				return nil, self.wr_err
			end
		end
		if self.closing then
			return true, function ()
				if owned then self:_release_wr(owner) end
				return nil, 'closed'
			end
		end

		if not owned then
			if not self:_acquire_wr(owner) then
				return false, K_WRGATE
			end
			owned = true
		end

		if not can_enqueue() then
			self:_kick_pump()
			return false, K_SPACE
		end

		return true, function ()
			if self.closing or self.terminated ~= nil or self.wr_err then
				self:_release_wr(owner)
				return nil, 'closed'
			end
			if self.tx:read_avail() == 0 and len > rb_cap(self.tx) then
				self._tx_big = { s = str, off = 0 }
			else
				self.tx:put(str)
			end
			self:_release_wr(owner)
			self:_kick_pump()
			return len, nil
		end
	end

	local function wrap_fn(commit)
		return commit()
	end

	local ev = wait.waitable2(register, probe_step, run_step, wrap_fn)
	return ev:on_abort(function ()
		if owned then self:_release_wr(owner) end
	end)
end

function Stream:write_op(...)
	local n = select('#', ...)
	if n == 0 then return op.always(0, nil) end
	if n == 1 then
		local v = select(1, ...)
		return self:write_bytes_op((type(v) == 'string') and v or tostring(v))
	end
	local parts = {}
	for i = 1, n do
		local v = select(i, ...)
		parts[i] = (type(v) == 'string') and v or tostring(v)
	end
	return self:write_bytes_op(table.concat(parts))
end

function Stream:write_all_op(s)
	return self:write_bytes_op(s)
end

function Stream:flush_op()
	assert(self.tx, 'stream is not writable')

	local function drained()
		return (self._tx_big == nil) and (self.tx:read_avail() == 0)
	end

	local function register(task, _, _, _want)
		return self._ws:add(K_DRAIN, task)
	end

	local function probe_step()
		local terr = term_err(self)
		if terr then return true, function () return nil, terr end end
		if self.wr_err then return true, function () return nil, self.wr_err end end
		if drained() then return true, function () return true, nil end end
		return false, K_DRAIN
	end

	local function run_step()
		local terr = term_err(self)
		if terr then return true, function () return nil, terr end end
		if self.wr_err then return true, function () return nil, self.wr_err end end
		if drained() then return true, function () return true, nil end end
		self:_kick_pump()
		return false, K_DRAIN
	end

	local function wrap_fn(commit)
		return commit()
	end

	return wait.waitable2(register, probe_step, run_step, wrap_fn)
end

function Stream:close_op(opts)
	opts = opts or {}
	local terminate_on_abort = not not opts.terminate_on_abort
	local started = false

	local function register(task, _, _, want)
		if want == K_DRAIN then return self._ws:add(K_DRAIN, task) end
		return self._ws:add(K_TERM, task)
	end

	local function probe_step()
		if self.closed then
			return true, function () return true, nil end
		end
		return false, K_TERM
	end

	local function run_step()
		if self.closed then
			return true, function () return true, nil end
		end

		if self.terminated ~= nil then
			return true, function () return nil, self.terminated end
		end

		if not started then
			started = true
			self.closing = true
			-- wake writers waiting for gate/space
			ws_notify_all(self, K_WRGATE)
			ws_notify_all(self, K_SPACE)
			ws_notify_all(self, K_TERM)
		end

		-- If writable, flush before closing; if not writable, close immediately.
		if self.tx and (self._tx_big ~= nil or self.tx:read_avail() > 0) then
			self:_kick_pump()
			return false, K_DRAIN
		end

		local ok, err = true, nil
		if self.io and self.io.close then
			ok, err = self.io:close()
		end
		self.io = nil
		self.closed = true

		-- wake all blocked ops
		ws_notify_all(self, K_TERM)
		ws_notify_all(self, K_RDGATE)
		ws_notify_all(self, K_WRGATE)
		ws_notify_all(self, K_SPACE)
		ws_notify_all(self, K_DRAIN)

		if not ok then
			return true, function () return nil, err end
		end
		return true, function () return true, nil end
	end

	local function wrap_fn(commit)
		return commit()
	end

	local ev = wait.waitable2(register, probe_step, run_step, wrap_fn)

	return ev:on_abort(function ()
		if terminate_on_abort then
			self:terminate('close aborted')
		end
	end)
end

function Stream:terminate(reason)
	if self.terminated ~= nil then return true end
	self.terminated = reason or 'terminated'
	self.closing = true

	self:_stop_pump_wait()
	if self.io and self.io.close and not self.closed then
		pcall(function () self.io:close() end)
	end
	self.io = nil
	self.closed = true

	if self.rx then self.rx:reset() end
	if self.tx then self.tx:reset() end
	self.pb = nil
	self._tx_big = nil

	ws_notify_all(self, K_TERM)
	ws_notify_all(self, K_RDGATE)
	ws_notify_all(self, K_WRGATE)
	ws_notify_all(self, K_SPACE)
	ws_notify_all(self, K_DRAIN)

	return true
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

	if self.tx then
		local ok, err = perform(self:flush_op())
		if not ok then return nil, err end
	end

	if self.rx then self.rx:reset() end
	self.pb = nil
	self.eof = false
	self.rd_err = nil

	return self.io:seek(whence, offset)
end

function Stream:setvbuf(mode)
	if mode ~= 'no' and mode ~= 'line' and mode ~= 'full' then
		error('bad mode: ' .. tostring(mode), 2)
	end
	self.bufmode = mode
	self.line_buffering = (mode == 'line')
	return self
end

function Stream:filename()
	return self.io and self.io.filename
end

-- Synchronous wrappers
function Stream:read_some(max) return perform(self:read_some_op(max)) end

function Stream:read_line(opts) return perform(self:read_line_op(opts)) end

function Stream:read_exactly(n) return perform(self:read_exactly_op(n)) end

function Stream:write(...) return perform(self:write_op(...)) end

function Stream:flush() return perform(self:flush_op()) end

function Stream:close(opts) return perform(self:close_op(opts)) end

----------------------------------------------------------------------
-- Constructor / helpers
----------------------------------------------------------------------

---@param io_backend StreamBackend
---@param readable? boolean
---@param writable? boolean
---@param bufsize? integer
---@return Stream
local function open(io_backend, readable, writable, bufsize)
	local s = setmetatable({
		io              = io_backend,
		rx              = (readable ~= false) and RingBuf.new(bufsize or DEFAULT_BUF) or nil,
		tx              = (writable ~= false) and RingBuf.new(bufsize or DEFAULT_BUF) or nil,
		pb              = nil,
		eof             = false,
		rd_err          = nil,
		wr_err          = nil,
		closing         = false,
		closed          = false,
		terminated      = nil,
		bufmode         = 'full',
		line_buffering  = false,
		_ws             = wait.new_waitset(),
		_rd_owner       = nil,
		_wr_owner       = nil,
		_tx_big         = nil,
		_pump_wait      = nil,
		_pump_scheduled = false,
	}, Stream)

	s._pump = { run = function () s:_pump_run() end }
	return s
end

local function is_stream(x)
	return type(x) == 'table' and getmetatable(x) == Stream
end

return {
	open      = open,
	is_stream = is_stream,
	Stream    = Stream,
}

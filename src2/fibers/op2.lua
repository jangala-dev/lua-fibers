-- fibers/op2.lua
--
-- Transactional ops: preview/commit protocol with targeted waiting on Pulses and pulse unions.
--
-- Contract (offerless commit):
--   * preview() -> Pulse|PulseUnion|nil, key|nil, payload|nil
--       - If first result is non-nil: op is pending; caller should await it.
--       - Else: op is ready with opaque key and packed payload.
--   * commit() -> payload|nil
--       - Must not block and must not return a waitable.
--       - Commits the reservation/state established by the most recent ready preview().
--   * abort() -> nil
--       - Rolls back any uncommitted reservation; idempotent; op remains retryable.

local runtime   = require 'fibers.runtime2'
local pulse_mod = require 'fibers.pulse2'
local Pulse     = pulse_mod.Pulse

local await = runtime.await

local unpack = rawget(table, 'unpack') or _G.unpack
local pack   = rawget(table, 'pack') or function (...) return { n = select('#', ...), ... } end

local EMPTY = { n = 0 }

----------------------------------------------------------------------
-- Base op methods
----------------------------------------------------------------------

local Op = {}
Op.__index = Op

local function extend(type_table)
	return setmetatable(type_table, { __index = Op })
end

-- Optional stability/invalidation pulse for the current ready state.
function Op:watch()
	return nil
end

local function is_pulse(x)
	return type(x) == 'table' and getmetatable(x) == Pulse
end

----------------------------------------------------------------------
-- Pulse unions (Pulse or { n=k, [1]=p1, ... })
----------------------------------------------------------------------

local function add_pulse_dedupe(arr, n, p)
	if not p then return n end
	if not is_pulse(p) then error('pending waitable contains non-pulse', 0) end
	for i = 1, n do
		if arr[i] == p then return n end
	end
	n = n + 1
	arr[n] = p
	return n
end

local function add_waitable_dedupe(arr, n, w)
	if not w then return n end
	if is_pulse(w) then
		return add_pulse_dedupe(arr, n, w)
	end
	if type(w) ~= 'table' then
		error('pending waitable must be a Pulse or pulse union table', 0)
	end
	local m = w.n or #w
	if m <= 0 then error('pending waitable union is empty', 0) end
	for i = 1, m do
		n = add_pulse_dedupe(arr, n, w[i])
	end
	return n
end

-- Scratch-array hygiene:
-- Avoid clearing tables on every iteration. Instead, track how big the scratch
-- table has grown and only clear the tail occasionally (when it has shrunk a lot).
-- This reduces instruction count in hot loops under LuaJIT.
local function scratch_maybe_shrink(arr, max_used, used_now)
	-- Keep arr.n consistent with current use (caller may set it later when returning a union).
	arr.n = nil

	if used_now > max_used then
		return used_now
	end

	-- Only pay the cost of clearing when:
	--   * we have grown to a moderately large size, and
	--   * we have now shrunk to less than a quarter of that size.
	if max_used > 64 and used_now * 4 < max_used then
		for i = used_now + 1, max_used do
			arr[i] = nil
		end
		return used_now
	end

	return max_used
end

local function wait_from_list(arr, n)
	if n <= 0 then
		error('op pending but no pulse was returned', 0)
	elseif n == 1 then
		local p = arr[1]
		arr.n  = nil
		return p
	else
		arr.n = n
		return arr
	end
end

----------------------------------------------------------------------
-- wrap
----------------------------------------------------------------------

local WrapOp = {}
WrapOp.__index = WrapOp
extend(WrapOp)

function Op:wrap(f)
	if type(f) ~= 'function' then error('wrap expects a function', 2) end
	return setmetatable({
		inner = self,
		f     = f,
		_ck   = nil, -- cached key
		_cp   = nil, -- cached packed payload
	}, WrapOp)
end

function WrapOp:preview()
	local w, key, payload = self.inner:preview()
	if w then
		return w, nil, nil
	end

	payload = payload or EMPTY

	if self._ck ~= key then
		self._ck = key
		local out = pack(self.f(unpack(payload, 1, payload.n)))
		self._cp = (out.n == 0) and EMPTY or out
	end

	return nil, key, self._cp
end

function WrapOp:commit()
	-- Commit inner; under contract this must be immediate.
	local payload = self.inner:commit() or EMPTY

	-- If we have a cached wrapped payload for the current ready key, reuse it.
	if self._cp then
		return self._cp
	end

	local out = pack(self.f(unpack(payload, 1, payload.n)))
	return (out.n == 0) and EMPTY or out
end

function WrapOp:abort()
	self._ck, self._cp = nil, nil
	return self.inner:abort()
end

function WrapOp:watch()
	local inner = self.inner
	local w = inner.watch
	if w then return w(inner) end
	return nil
end

----------------------------------------------------------------------
-- perform(op): preview until ready; then commit (no args)
----------------------------------------------------------------------

local function perform(opv)
	while true do
		local w, _key, payload = opv:preview()
		if w then
			await(w)
		else
			local out = opv:commit() or payload or EMPTY
			if out.n == 0 then return end
			return unpack(out, 1, out.n)
		end
	end
end

----------------------------------------------------------------------
-- choice(op1, op2, ...)
----------------------------------------------------------------------

local ChoiceOp = {}
ChoiceOp.__index = ChoiceOp
extend(ChoiceOp)

local function choice(...)
	local ops = { ... }
	if #ops == 0 then error('choice expects at least one op', 2) end
	if #ops == 1 then return ops[1] end

	local sel = { winner = nil }
	for i = 1, #ops do
		local o = ops[i]
		local attach = o._attach_select
		if attach then attach(o, sel) end
	end

	return setmetatable({
		ops = ops,
		n   = #ops,
		rr  = 1,

		key      = 0,    -- opaque key for this choice readiness
		sig_i    = nil,  -- winner index at last ready preview
		sig_ckey = nil,  -- winner child key at last ready preview

		winner_i   = nil,
		winner_ckey= nil,
		winner_pay = EMPTY,

		done     = false,
		done_pay = nil,

		_sel  = sel,
		_pend = {}, -- scratch pulse list/union table
		_pend_max = 0,
	}, ChoiceOp)
end

function ChoiceOp:preview()
	if self.done then
		return nil, self.key, self.done_pay or EMPTY
	end

	-- Validate cached winner if present.
	local wi = self.winner_i
	if wi then
		local w, ckey, pay = self.ops[wi]:preview()
		if (not w) and ckey == self.winner_ckey then
			self.winner_pay = pay or EMPTY
			return nil, self.key, self.winner_pay
		end
		self.winner_i, self.winner_ckey = nil, nil
		self.winner_pay = EMPTY
	end

	local pend = self._pend
	local npend = 0
	local pend_max = self._pend_max

	local n = self.n
	local start = self.rr
	self.rr = (self.rr % n) + 1

	for k = 0, n - 1 do
		local i = ((start + k - 1) % n) + 1
		local w, ckey, pay = self.ops[i]:preview()

		if not w then
			self.winner_i    = i
			self.winner_ckey = ckey
			self.winner_pay  = pay or EMPTY

			-- Advance our own key when the winning signature changes.
			if self.sig_i ~= i or self.sig_ckey ~= ckey then
				self.key      = self.key + 1
				self.sig_i    = i
				self.sig_ckey = ckey
			end

			self._pend_max = scratch_maybe_shrink(pend, pend_max, 0)

			return nil, self.key, self.winner_pay
		end

		npend = add_waitable_dedupe(pend, npend, w)
	end

	-- Pending path: return a pulse or union. Avoid clearing the tail each time.
	pend_max = scratch_maybe_shrink(pend, pend_max, npend)
	self._pend_max = pend_max
	return wait_from_list(pend, npend), nil, nil
end

function ChoiceOp:commit()
	if self.done then
		return self.done_pay or EMPTY
	end
	if not self.winner_i then
		error('choice.commit: commit without a ready preview', 0)
	end

	local wi = self.winner_i
	local committed = self.ops[wi]:commit()

	for i = 1, self.n do
		if i ~= wi then self.ops[i]:abort() end
	end

	self.done     = true
	self.done_pay = committed or self.winner_pay or EMPTY

	self.winner_i, self.winner_ckey = nil, nil
	self.winner_pay = EMPTY

	return self.done_pay
end

function ChoiceOp:abort()
	-- Roll back any observed reservations; remain retryable.
	for i = 1, self.n do
		self.ops[i]:abort()
	end
	self.winner_i, self.winner_ckey = nil, nil
	self.winner_pay = EMPTY
	-- Do not clear the scratch array eagerly.
	self._pend_max = scratch_maybe_shrink(self._pend, self._pend_max, 0)
end

----------------------------------------------------------------------
-- all(op1, op2, ...)
----------------------------------------------------------------------

local AllOp = {}
AllOp.__index = AllOp
extend(AllOp)

local function all(...)
	local ops = { ... }
	if #ops == 0 then error('all expects at least one op', 2) end
	if #ops == 1 then return ops[1] end

	return setmetatable({
		ops = ops,
		n   = #ops,

		key      = 0,
		prepared = false,

		arm_key = {},              -- child keys for last ready preview
		out_pay = { n = #ops },     -- packed payload per arm

		done = false,

		_pend = {}, -- scratch pulse list/union table
		_pend_max = 0,
	}, AllOp)
end

function AllOp:preview()
	if self.done then
		return nil, self.key, self.out_pay
	end

	local pend = self._pend
	local npend = 0
	local pend_max = self._pend_max
	local changed = false

	for i = 1, self.n do
		local w, ckey, pay = self.ops[i]:preview()
		if w then
			npend = add_waitable_dedupe(pend, npend, w)
		else
			if self.arm_key[i] ~= ckey then
				changed = true
				self.arm_key[i] = ckey
			end
			self.out_pay[i] = pay or EMPTY
		end
	end

	if npend ~= 0 then
		-- Roll back any reservations we may have observed.
		for i = 1, self.n do
			if self.arm_key[i] ~= nil then
				self.ops[i]:abort()
				self.arm_key[i] = nil
				self.out_pay[i] = nil
			end
		end
		self.prepared = false

		-- Return pending union; avoid clearing tail every time.
		pend_max = scratch_maybe_shrink(pend, pend_max, npend)
		self._pend_max = pend_max
		return wait_from_list(pend, npend), nil, nil
	end

	for j = 1, #pend do pend[j] = nil end
	-- Ready path: we are not returning the pending union.
	self._pend_max = scratch_maybe_shrink(pend, pend_max, 0)

	-- Ready as a set; advance key if signature changed.
	if changed or not self.prepared then
		self.key = self.key + 1
	end
	self.prepared = true
	self.out_pay.n = self.n

	return nil, self.key, self.out_pay
end

function AllOp:commit()
	if self.done then
		return self.out_pay
	end
	if not self.prepared then
		error('all.commit: commit without a ready preview', 0)
	end

	for i = 1, self.n do
		local pay = self.ops[i]:commit()
		self.out_pay[i] = pay or self.out_pay[i] or EMPTY
	end

	for i = 1, self.n do
		self.arm_key[i] = nil
	end

	self.prepared = false
	self.done = true
	return self.out_pay
end

function AllOp:abort()
	for i = 1, self.n do
		self.ops[i]:abort()
		self.arm_key[i] = nil
		self.out_pay[i] = nil
	end
	self.prepared = false
end

----------------------------------------------------------------------
-- and_then(k): transactional bind (offerless)
----------------------------------------------------------------------

local AndThenOp = {}
AndThenOp.__index = AndThenOp
extend(AndThenOp)

local function is_op_like(x)
	return type(x) == 'table'
		and type(x.preview) == 'function'
		and type(x.commit) == 'function'
		and type(x.abort) == 'function'
end

function Op:and_then(k)
	if type(k) ~= 'function' then error('and_then expects a function', 2) end
	return setmetatable({
		lhs = self,
		k   = k,

		key     = 0,
		sig_lk  = nil,
		sig_rk  = nil,

		lk   = nil,
		lw   = nil,
		rhs  = nil,
		rk   = nil,
		rpay = EMPTY,

		done     = false,
		done_pay = nil,

		_w_arr = {}, -- scratch union
		_w_max = 0,
	}, AndThenOp)
end

function AndThenOp:_clear_plan()
	self.lk, self.lw = nil, nil
	self.rk = nil
	self.rpay = EMPTY
	self.sig_lk, self.sig_rk = nil, nil
	self.rhs = nil
end

function AndThenOp:_wait_union2(w1, w2)
	local a = self._w_arr
	local n = 0
	n = add_waitable_dedupe(a, n, w1)
	n = add_waitable_dedupe(a, n, w2)
	-- Avoid clearing tail eagerly; shrink under hysteresis.
	self._w_max = scratch_maybe_shrink(a, self._w_max, n)
	return wait_from_list(a, n)
end

function AndThenOp:preview()
	if self.done then
		return nil, self.key, self.done_pay or EMPTY
	end

	-- Preview LHS.
	local w, lk, lpay = self.lhs:preview()
	if w then
		if self.rhs then self.rhs:abort() end
		self:_clear_plan()
		return w, nil, nil
	end

	lpay = lpay or EMPTY

	-- Re-derive RHS if LHS key changed.
	if self.lk ~= lk then
		if self.rhs then self.rhs:abort() end
		self.rhs  = nil
		self.rk   = nil
		self.rpay = EMPTY

		self.lk = lk
		local watch = self.lhs.watch
		self.lw = watch and watch(self.lhs) or nil

		local rhs = self.k(unpack(lpay, 1, lpay.n))
		if not is_op_like(rhs) then
			error('and_then: function must return an op-like table', 0)
		end
		self.rhs = rhs
	end

	-- Preview RHS.
	local rw, rk, rpay = self.rhs:preview()
	if rw then
		-- Do not hold reservations across the wait.
		local lw = self.lw
		self.rhs:abort()
		self.lhs:abort()
		self:_clear_plan()
		return self:_wait_union2(rw, lw), nil, nil
	end

	self.rk   = rk
	self.rpay = rpay or EMPTY

	-- Advance key when (lk, rk) signature changes.
	if self.sig_lk ~= lk or self.sig_rk ~= rk then
		self.key     = self.key + 1
		self.sig_lk  = lk
		self.sig_rk  = rk
	end

	return nil, self.key, self.rpay
end

function AndThenOp:commit()
	if self.done then
		return self.done_pay or EMPTY
	end
	if not self.rhs or self.lk == nil or self.rk == nil then
		error('and_then.commit: commit without a ready preview', 0)
	end

	-- Commit LHS then RHS.
	self.lhs:commit()
	local out = self.rhs:commit() or self.rpay or EMPTY

	self.done     = true
	self.done_pay = out
	self:_clear_plan()

	return out
end

function AndThenOp:abort()
	if self.rhs then self.rhs:abort() end
	self.lhs:abort()
	self.done_pay = nil
	self:_clear_plan()
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

return {
	perform = perform,

	Op     = Op,
	extend = extend,
	EMPTY  = EMPTY,

	pack   = pack,
	unpack = unpack,

	choice = choice,
	all    = all,
}

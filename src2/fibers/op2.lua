-- fibers/op2.lua
--
-- Transactional ops: preview/commit protocol with targeted waiting on Pulses and pulse unions.
-- Contract (strengthened):
--   * preview() -> Pulse|PulseUnion|nil, offer|nil, payload|nil
--       - If first result is non-nil: op is pending; caller should await it.
--       - Else: op is ready for 'offer' with packed payload.
--   * commit(offer) -> payload|nil
--       - Must not block and must not return a waitable.
--       - If called without a matching ready preview, this is an error.
--   * abort(offer?) -> nil
--       - Rolls back any uncommitted reservation; idempotent.

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

-- Optional stability/invalidation pulse for a ready offer.
function Op:watch(_offer)
	return nil
end

local function is_pulse(x)
	return type(x) == 'table' and getmetatable(x) == Pulse
end

----------------------------------------------------------------------
-- Pulse unions
----------------------------------------------------------------------

-- A waitable is either:
--   * a Pulse, or
--   * a pulse union table: { n = k, [1] = p1, [2] = p2, ... }
--
-- Helper: add a pulse with dedupe.
local function add_pulse_dedupe(arr, n, p)
	if not p then return n end
	if not is_pulse(p) then
		error('pending waitable contains non-pulse', 0)
	end
	for i = 1, n do
		if arr[i] == p then
			return n
		end
	end
	n = n + 1
	arr[n] = p
	return n
end

-- Helper: add a waitable (Pulse or union) into arr, flattening and deduping.
local function add_waitable_dedupe(arr, n, w)
	if not w then return n end
	if is_pulse(w) then
		return add_pulse_dedupe(arr, n, w)
	end

	if type(w) ~= 'table' then
		error('pending waitable must be a Pulse or pulse union table', 0)
	end

	local m = w.n or #w
	if m <= 0 then
		error('pending waitable union is empty', 0)
	end

	for i = 1, m do
		n = add_pulse_dedupe(arr, n, w[i])
	end
	return n
end

-- Return a canonical wait value from (arr, n):
--   * n == 1 -> return the single Pulse
--   * n > 1  -> return the union table (with .n set)
local function wait_from_list(arr, n)
	if n <= 0 then
		error('op pending but no pulse was returned', 0)
	elseif n == 1 then
		local p = arr[1]
		arr[1] = nil
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
		_co   = nil, -- cached offer
		_cp   = nil, -- cached packed payload
	}, WrapOp)
end

function WrapOp:preview()
	local w, offer, payload = self.inner:preview()
	if w then
		return w, nil, nil
	end

	payload = payload or EMPTY

	-- Cache wrapped payload per offer.
	if self._co ~= offer then
		self._co = offer
		local out = pack(self.f(unpack(payload, 1, payload.n)))
		self._cp = (out.n == 0) and EMPTY or out
	end

	return nil, offer, self._cp
end

function WrapOp:commit(offer)
	-- Under the strengthened contract, commit must not pend.
	local payload = self.inner:commit(offer) or EMPTY

	-- If cached for that offer, reuse.
	if self._co == offer and self._cp then
		return self._cp
	end

	local out = pack(self.f(unpack(payload, 1, payload.n)))
	return (out.n == 0) and EMPTY or out
end

function WrapOp:abort(offer)
	self._co, self._cp = nil, nil
	return self.inner:abort(offer)
end

function WrapOp:watch(offer)
	local inner = self.inner
	local w = inner.watch
	if w then return w(inner, offer) end
	return nil
end

----------------------------------------------------------------------
-- perform(op): preview until ready; then commit (must not pend)
----------------------------------------------------------------------

local function perform(opv)
	while true do
		local w, offer, payload = opv:preview()
		if w then
			await(w)
		else
			local out = opv:commit(offer) or payload or EMPTY
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

	-- Optional arbitration object for primitives that support it.
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

		offer     = 0,
		sig_i     = nil,
		sig_offer = nil,

		winner_i     = nil,
		winner_offer = nil,
		winner_pay   = EMPTY,

		done     = false,
		done_pay = nil,

		_sel = sel,

		_pend = {}, -- scratch pulse list/union table
	}, ChoiceOp)
end

function ChoiceOp:preview()
	if self.done then
		return nil, self.offer, self.done_pay or EMPTY
	end

	-- Validate cached winner if present.
	local wi = self.winner_i
	if wi then
		local w, off, pay = self.ops[wi]:preview()
		if (not w) and off == self.winner_offer then
			self.winner_pay = pay or EMPTY
			return nil, self.offer, self.winner_pay
		end
		self.winner_i, self.winner_offer = nil, nil
		self.winner_pay = EMPTY
	end

	local pend = self._pend
	local npend = 0

	local n = self.n
	local start = self.rr
	self.rr = (self.rr % n) + 1

	for k = 0, n - 1 do
		local i = ((start + k - 1) % n) + 1
		local w, off, pay = self.ops[i]:preview()

		if not w then
			self.winner_i     = i
			self.winner_offer = off
			self.winner_pay   = pay or EMPTY

			if self.sig_i ~= i or self.sig_offer ~= off then
				self.offer     = self.offer + 1
				self.sig_i     = i
				self.sig_offer = off
			end

			-- Clear scratch list.
			for j = 1, npend do pend[j] = nil end
			pend.n = nil

			return nil, self.offer, self.winner_pay
		end

		-- Pending: flatten and dedupe any unions.
		npend = add_waitable_dedupe(pend, npend, w)
	end

	-- Trim trailing entries if any (defensive).
	for j = npend + 1, #pend do pend[j] = nil end

	return wait_from_list(pend, npend), nil, nil
end

function ChoiceOp:commit(expected_offer)
	if self.done then
		return self.done_pay or EMPTY
	end

	if expected_offer ~= self.offer or not self.winner_i then
		error('choice.commit: stale offer (commit without valid ready preview)', 0)
	end

	local wi   = self.winner_i
	local woff = self.winner_offer

	local committed = self.ops[wi]:commit(woff)

	for i = 1, self.n do
		if i ~= wi then self.ops[i]:abort() end
	end

	self.done     = true
	self.done_pay = committed or self.winner_pay or EMPTY
	self.winner_i, self.winner_offer = nil, nil
	self.winner_pay = EMPTY

	return self.done_pay
end

function ChoiceOp:abort(_offer)
	if self.done then return end
	for i = 1, self.n do
		self.ops[i]:abort()
	end
	self.done = true
	self.done_pay = nil
	self.winner_i, self.winner_offer = nil, nil
	self.winner_pay = EMPTY
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

		offer    = 0,
		prepared = false,

		arm_offer = {},
		out_pay   = { n = #ops },

		done = false,

		_pend = {}, -- scratch pulse list/union table
	}, AllOp)
end

function AllOp:preview()
	if self.done then
		return nil, self.offer, self.out_pay
	end

	local pend = self._pend
	local npend = 0

	for i = 1, self.n do
		local w, off, pay = self.ops[i]:preview()
		if w then
			npend = add_waitable_dedupe(pend, npend, w)
		else
			self.arm_offer[i] = off
			self.out_pay[i]   = pay or EMPTY
		end
	end

	if npend ~= 0 then
		-- Abort any observed reservations.
		for i = 1, self.n do
			local off = self.arm_offer[i]
			if off ~= nil then
				self.ops[i]:abort(off)
				self.arm_offer[i] = nil
				self.out_pay[i]   = nil
			end
		end
		self.prepared = false

		for j = npend + 1, #pend do pend[j] = nil end
		return wait_from_list(pend, npend), nil, nil
	end

	-- Ready as a set.
	for j = 1, #pend do pend[j] = nil end
	pend.n = nil

	self.offer = self.offer + 1
	self.prepared = true
	self.out_pay.n = self.n
	return nil, self.offer, self.out_pay
end

function AllOp:commit(expected_offer)
	if self.done then
		return self.out_pay
	end

	if (not self.prepared) or expected_offer ~= self.offer then
		error('all.commit: stale offer (commit without valid ready preview)', 0)
	end

	for i = 1, self.n do
		local pay = self.ops[i]:commit(self.arm_offer[i])
		self.out_pay[i] = pay or self.out_pay[i] or EMPTY
	end

	for i = 1, self.n do
		self.arm_offer[i] = nil
	end

	self.prepared = false
	self.done = true
	return self.out_pay
end

function AllOp:abort(_offer)
	if self.done then return end
	for i = 1, self.n do
		local off = self.arm_offer[i]
		if off ~= nil then
			self.ops[i]:abort(off)
			self.arm_offer[i] = nil
		else
			self.ops[i]:abort()
		end
		self.out_pay[i] = nil
	end
	self.prepared = false
	self.done = true
end

----------------------------------------------------------------------
-- and_then(k): transactional bind
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

		offer  = 0,
		sig_lo = nil,
		sig_ro = nil,

		lo   = nil,
		lw   = nil, -- lhs watch pulse/union for lo (may be nil)
		rhs  = nil,
		ro   = nil,
		rpay = EMPTY,

		done     = false,
		done_pay = nil,

		_w_arr = {}, -- scratch union
	}, AndThenOp)
end

local function abort_offer(opv, offer)
	if not opv then return end
	if offer ~= nil then
		opv:abort(offer)
	else
		opv:abort()
	end
end

function AndThenOp:_clear_plan()
	self.lo, self.lw = nil, nil
	self.ro = nil
	self.rpay = EMPTY
	self.sig_lo, self.sig_ro = nil, nil
	self.rhs = nil
end

function AndThenOp:_wait_union2(w1, w2)
	local a = self._w_arr
	local n = 0
	n = add_waitable_dedupe(a, n, w1)
	n = add_waitable_dedupe(a, n, w2)
	for i = n + 1, #a do a[i] = nil end
	return wait_from_list(a, n)
end

function AndThenOp:preview()
	if self.done then
		return nil, self.offer, self.done_pay or EMPTY
	end

	local lhs = self.lhs
	local w, lo, lpay = lhs:preview()
	if w then
		if self.rhs then abort_offer(self.rhs, self.ro) end
		self:_clear_plan()
		return w, nil, nil
	end

	lpay = lpay or EMPTY

	if self.lo ~= lo then
		if self.rhs then abort_offer(self.rhs, self.ro) end
		self.rhs  = nil
		self.ro   = nil
		self.rpay = EMPTY

		self.lo = lo
		local watch = lhs.watch
		self.lw = watch and watch(lhs, lo) or nil

		local rhs = self.k(unpack(lpay, 1, lpay.n))
		if not is_op_like(rhs) then
			error('and_then: function must return an op-like table', 0)
		end
		self.rhs = rhs
	end

	local rhs = self.rhs
	local rw, ro, rpay = rhs:preview()
	if rw then
		-- Do not hold reservations across the wait.
		local lw = self.lw
		rhs:abort()
		lhs:abort(lo)
		self:_clear_plan()
		return self:_wait_union2(rw, lw), nil, nil
	end

	self.ro   = ro
	self.rpay = rpay or EMPTY

	if self.sig_lo ~= lo or self.sig_ro ~= ro then
		self.offer  = self.offer + 1
		self.sig_lo = lo
		self.sig_ro = ro
	end

	return nil, self.offer, self.rpay
end

function AndThenOp:commit(expected_offer)
	if self.done then
		return self.done_pay or EMPTY
	end

	if expected_offer ~= self.offer or not self.rhs or self.lo == nil or self.ro == nil then
		error('and_then.commit: stale offer (commit without valid ready preview)', 0)
	end

	local lhs = self.lhs
	local lo  = self.lo
	local rhs = self.rhs
	local ro  = self.ro

	lhs:commit(lo)
	local out = rhs:commit(ro) or self.rpay or EMPTY

	self.done     = true
	self.done_pay = out
	self:_clear_plan()

	return out
end

function AndThenOp:abort(_offer)
	if self.done then return end

	if self.rhs then
		abort_offer(self.rhs, self.ro)
	end
	if self.lo ~= nil then
		self.lhs:abort(self.lo)
	else
		self.lhs:abort()
	end

	self.done = true
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

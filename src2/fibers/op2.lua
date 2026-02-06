-- fibers/op2.lua
--
-- Transactional ops: a two-phase preview/commit protocol with targeted waiting.
--
-- Purpose
--   Provides a small algebra of composable, one-shot operations ("ops") that are the only
--   language of waiting. Fibres block only inside perform(op), by awaiting waitables returned
--   from preview/commit.
--
-- Op protocol
--   * op:preview() -> waitable|nil, offer|nil, payload|nil
--       - If waitable ~= nil: operation is pending; caller should await it.
--       - Else: operation is ready under 'offer', with a packed payload (table {n=..., ...}).
--       - preview is non-consuming: it may establish a reservation but must not commit effects.
--   * op:commit(offer) -> waitable|nil, payload|nil
--       - If waitable ~= nil: offer is stale or not commit-eligible; caller should await and retry.
--       - Else: commits irreversibly and returns packed payload; must not block.
--   * op:abort(offer?) -> nil
--       - Rolls back any uncommitted reservation; idempotent.
--
-- Targeted waiting
--   * Pending states return concrete waitables (typically pulses owned by primitives).
--   * choice/all build an Any view over the set of pending waitables from their last preview pass.
--
-- Composition
--   * wrap(f): maps a ready payload through f at preview-time (cached per offer), reusing on commit.
--   * choice(...): selects the first ready arm (round-robin), aborting losers on commit.
--   * all(...): requires all arms ready; aborts observed reservations if any arm is pending.
--   * and_then(k): transactional bind (dynamic derivation):
--       - Preview LHS; when LHS is ready, call k(...) with LHS preview values to obtain an RHS op.
--       - If RHS is pending, abort RHS and abort the LHS reservation (do not hold it); then wait on
--         RHS's pending waitable, optionally combined with LHS:watch(offer) if provided.
--       - If RHS is ready, commit LHS first, then commit RHS; return RHS payload only.
--       - This supports “derive RHS as LHS changes” while ensuring LHS reservations are not held
--         across waits when RHS cannot immediately commit.

local runtime   = require 'fibers.runtime2'
local pulse_mod = require 'fibers.pulse2'

local await   = runtime.await
local AnyView = pulse_mod.Any -- view type; use AnyView.new()

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

-- Optional stability/invalidation waitable for a ready offer.
-- Default is "no watchable".
function Op:watch(_offer)
	return nil
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

	-- cache wrapped payload per offer
	if self._co ~= offer then
		self._co = offer
		local out = pack(self.f(unpack(payload, 1, payload.n)))
		self._cp = (out.n == 0) and EMPTY or out
	end

	return nil, offer, self._cp
end

function WrapOp:commit(offer)
	local w, payload = self.inner:commit(offer)
	if w then
		return w, nil
	end

	-- if cached for that offer, reuse
	if self._co == offer and self._cp then
		return nil, self._cp
	end

	return nil, payload or EMPTY
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
-- perform(op)
----------------------------------------------------------------------

local function perform(opv)
	while true do
		local w, offer, payload = opv:preview()
		if w then
			await(w)
		else
			local cw, out = opv:commit(offer)
			if cw then
				await(cw)
			else
				out = out or payload or EMPTY
				if out.n == 0 then return end
				return unpack(out, 1, out.n)
			end
		end
	end
end

----------------------------------------------------------------------
-- Helper: pending waitable from (arr, n) using reusable AnyView
----------------------------------------------------------------------

local function pend_any(any_view, arr, n)
	if n == 0 then
		error('op pending but no waitable was returned', 0)
	end
	return any_view:set(arr, n)
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

	-- Optional arbitration object.
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

		-- pending dependency set from last preview()
		_pend   = {},
		_pend_n = 0,
		_any    = AnyView.new(), -- reusable view object
	}, ChoiceOp)
end

function ChoiceOp:preview()
	if self.done then
		self._pend_n = 0
		return nil, self.offer, self.done_pay or EMPTY
	end

	-- Validate cached winner if present.
	local wi = self.winner_i
	if wi then
		local w, off, pay = self.ops[wi]:preview()
		if (not w) and off == self.winner_offer then
			self.winner_pay = pay or EMPTY
			self._pend_n = 0
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

			-- commit offer changes only when the winning signature changes
			if self.sig_i ~= i or self.sig_offer ~= off then
				self.offer     = self.offer + 1
				self.sig_i     = i
				self.sig_offer = off
			end

			self._pend_n = 0
			return nil, self.offer, self.winner_pay
		end

		npend = npend + 1
		pend[npend] = w
	end

	-- clear trailing scratch
	for i = npend + 1, #pend do pend[i] = nil end
	self._pend_n = npend

	return pend_any(self._any, pend, npend), nil, nil
end

function ChoiceOp:commit(expected_offer)
	if self.done then
		return nil, self.done_pay or EMPTY
	end

	if expected_offer ~= self.offer or not self.winner_i then
		if self._pend_n ~= 0 then
			return pend_any(self._any, self._pend, self._pend_n), nil
		end
		error('choice.commit: stale offer with no pending waitable (commit without valid preview?)', 0)
	end

	local wi   = self.winner_i
	local woff = self.winner_offer

	local w, committed = self.ops[wi]:commit(woff)
	if w then
		-- Winner not commit-eligible; discard cached winner and wait on last pending set.
		self.winner_i, self.winner_offer = nil, nil
		self.winner_pay = EMPTY

		if self._pend_n ~= 0 then
			return pend_any(self._any, self._pend, self._pend_n), nil
		end
		if not w then
			error('choice.commit: winner returned pending with nil waitable', 0)
		end
		return w, nil
	end

	-- Abort losers.
	for i = 1, self.n do
		if i ~= wi then self.ops[i]:abort() end
	end

	self.done     = true
	self.done_pay = committed or self.winner_pay or EMPTY
	self._pend_n  = 0
	return nil, self.done_pay
end

function ChoiceOp:abort(_offer)
	if self.done then return end
	for i = 1, self.n do
		self.ops[i]:abort()
	end
	self.done = true
	self.done_pay = nil
	self._pend_n = 0
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
		out_pay   = { n = #ops }, -- packed payload per arm

		done = false,

		_pend   = {},
		_pend_n = 0,
		_any    = AnyView.new(),
	}, AllOp)
end

function AllOp:preview()
	if self.done then
		self._pend_n = 0
		return nil, self.offer, self.out_pay
	end

	local pend = self._pend
	local npend = 0

	for i = 1, self.n do
		local w, off, pay = self.ops[i]:preview()
		if w then
			npend = npend + 1
			pend[npend] = w
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

		for i = npend + 1, #pend do pend[i] = nil end
		self._pend_n = npend

		return pend_any(self._any, pend, npend), nil, nil
	end

	for i = 1, #pend do pend[i] = nil end
	self._pend_n = 0

	self.offer = self.offer + 1
	self.prepared = true
	self.out_pay.n = self.n
	return nil, self.offer, self.out_pay
end

function AllOp:commit(expected_offer)
	if self.done then
		return nil, self.out_pay
	end

	if (not self.prepared) or expected_offer ~= self.offer then
		if self._pend_n ~= 0 then
			return pend_any(self._any, self._pend, self._pend_n), nil
		end
		error('all.commit: stale offer with no pending waitable (commit without valid preview?)', 0)
	end

	for i = 1, self.n do
		local w, pay = self.ops[i]:commit(self.arm_offer[i])
		if w then
			-- Abort as a set and retry later.
			for j = 1, self.n do
				local off = self.arm_offer[j]
				if off ~= nil then
					self.ops[j]:abort(off)
					self.arm_offer[j] = nil
					self.out_pay[j]   = nil
				end
			end
			self.prepared = false

			if not w then
				error('all.commit: arm returned pending with nil waitable', 0)
			end
			return w, nil
		end
		self.out_pay[i] = pay or self.out_pay[i] or EMPTY
	end

	for i = 1, self.n do
		self.arm_offer[i] = nil
	end

	self.prepared = false
	self.done = true
	self._pend_n = 0
	return nil, self.out_pay
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
	self._pend_n = 0
end

----------------------------------------------------------------------
-- and_then(k)
--
-- Transactional bind:
--   * Preview LHS, derive RHS from its preview payload.
--   * If RHS is pending, abort LHS (do not hold its reservation) and abort RHS; wait on:
--         RHS waitable OR LHS watchable (if provided)
--   * If ready, commit LHS then RHS; return RHS payload only.
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

		offer = 0,
		sig_lo = nil,
		sig_ro = nil,

		-- cached plan
		lo   = nil,
		lw   = nil, -- lhs watchable for lo (may be nil)
		rhs  = nil,
		ro   = nil,
		rpay = EMPTY,

		done     = false,
		done_pay = nil,

		-- last pending waitable (for stale commit paths)
		_last_w = nil,

		-- scratch for combining [rhs_wait, lhs_watch]
		_w_arr = {},
		_any   = AnyView.new(),
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

function AndThenOp:_wait2(rw, lw)
	if not lw then
		return rw
	end
	local a = self._w_arr
	a[1] = rw
	a[2] = lw
	return self._any:set(a, 2)
end

function AndThenOp:preview()
	if self.done then
		self._last_w = nil
		return nil, self.offer, self.done_pay or EMPTY
	end

	-- Step 1: preview LHS.
	local lhs = self.lhs
	local w, lo, lpay = lhs:preview()
	if w then
		-- LHS pending; discard any cached RHS plan.
		if self.rhs then abort_offer(self.rhs, self.ro) end
		self:_clear_plan()

		self._last_w = w
		return w, nil, nil
	end

	lpay = lpay or EMPTY

	-- Step 2: (re)derive RHS if LHS offer changed.
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

	-- Step 3: preview RHS.
	local rhs = self.rhs
	local rw, ro, rpay = rhs:preview()
	if rw then
		-- RHS not immediately ready: abort RHS and LHS reservation and wait.
		-- Capture lw before clearing plan.
		local lw = self.lw

		rhs:abort()
		lhs:abort(lo)

		self:_clear_plan()

		local ww = self:_wait2(rw, lw)
		self._last_w = ww
		return ww, nil, nil
	end

	-- RHS ready.
	self.ro      = ro
	self.rpay    = rpay or EMPTY
	self._last_w = nil

	-- Outer offer changes when (lo, ro) signature changes.
	if self.sig_lo ~= lo or self.sig_ro ~= ro then
		self.offer  = self.offer + 1
		self.sig_lo = lo
		self.sig_ro = ro
	end

	return nil, self.offer, self.rpay
end

function AndThenOp:commit(expected_offer)
	if self.done then
		return nil, self.done_pay or EMPTY
	end

	-- Must match the last preview signature.
	if expected_offer ~= self.offer or not self.rhs or self.lo == nil or self.ro == nil then
		if self._last_w then
			return self._last_w, nil
		end
		error('and_then.commit: stale offer with no waitable (commit without valid preview?)', 0)
	end

	local lhs = self.lhs
	local lo  = self.lo
	local rhs = self.rhs
	local ro  = self.ro

	-- Commit LHS first (consumes/commits the proposal).
	local lw = lhs:commit(lo)
	if lw then
		-- Not commit-eligible; rollback RHS and LHS and wait.
		abort_offer(rhs, ro)
		lhs:abort(lo)

		self:_clear_plan()
		self._last_w = lw
		return lw, nil
	end

	-- Commit RHS.
	local rw, out = rhs:commit(ro)
	if rw then
		-- This should not happen without an intervening yield; treat as a bug.
		error('and_then: rhs became pending during commit (after lhs committed)', 0)
	end

	out           = out or self.rpay or EMPTY
	self.done     = true
	self.done_pay = out
	self._last_w  = nil

	return nil, out
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
	self._last_w = nil
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

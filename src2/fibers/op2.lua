-- fibers/op2.lua
--
-- Transactional ops with preview/commit and targeted waiting.
--
-- Protocol:
--   op:preview() -> waitable|nil, offer|nil, payload|nil
--     - If waitable ~= nil: pending
--     - Else: ready offer + packed payload
--
--   op:commit(offer) -> waitable|nil, payload|nil
--     - If waitable ~= nil: stale / not commit-eligible; await it then retry
--     - Else: committed packed payload
--
--   op:abort(offer?) -> nil
--
-- Targeted waiting:
-- * choice/all return a derived waitable representing "any relevant pending dependency".

local runtime   = require 'fibers.runtime2'
local pulse_mod = require 'fibers.pulse2'

local await = runtime.await
local any_from_array = pulse_mod.any_from_array

local unpack = rawget(table, 'unpack') or _G.unpack
local pack   = rawget(table, 'pack') or function (...) return { n = select('#', ...), ... } end

local EMPTY = { n = 0 }

-- A tiny waitable used when commit detects staleness but there is no specific dependency to await.
-- Subscribing schedules the fibre immediately for a re-preview pass.
local RETRY = {}
function RETRY:subscribe(token, epoch)
	-- Schedule this fibre now (targeted), without subscribing to any real pulse.
	token:_woken_by(self, runtime.scheduler(), epoch)
end

----------------------------------------------------------------------
-- Base op methods
----------------------------------------------------------------------

local Op = {}
Op.__index = Op

local function extend(type_table)
	return setmetatable(type_table, { __index = Op })
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
		_co   = nil,
		_cp   = nil,
	}, WrapOp)
end

function WrapOp:preview()
	local w, offer, payload = self.inner:preview()
	if w then
		return w, nil, nil
	end

	payload = payload or EMPTY

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
	if self._co == offer and self._cp then
		return nil, self._cp
	end
	return nil, payload or EMPTY
end

function WrapOp:abort(offer)
	self._co, self._cp = nil, nil
	return self.inner:abort(offer)
end

----------------------------------------------------------------------
-- perform(op)
----------------------------------------------------------------------

local function perform(opv)
	while true do
		local w, offer = opv:preview()
		if w then
			await(w)
		else
			local cw, out = opv:commit(offer)
			if cw then
				await(cw)
			else
				out = out or EMPTY
				if out.n == 0 then return end
				return unpack(out, 1, out.n)
			end
		end
	end
end

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------

local function wait_any(arr, n)
	if n == 0 then
		error('op pending but no waitable was returned', 0)
	end
	return any_from_array(arr, n)
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

		offer     = 0,
		sig_i     = nil,
		sig_offer = nil,

		winner_i     = nil,
		winner_offer = nil,
		winner_pay   = nil,

		done     = false,
		done_pay = nil,

		_sel = sel,

		_pend = {}, -- scratch waitables
		_wait = nil, -- last computed waitable when pending
	}, ChoiceOp)
end

function ChoiceOp:preview()
	if self.done then
		self._wait = nil
		return nil, self.offer, self.done_pay or EMPTY
	end

	self._wait = nil

	-- Validate cached winner if present.
	local wi = self.winner_i
	if wi then
		local w, off, pay = self.ops[wi]:preview()
		if (not w) and off == self.winner_offer then
			self.winner_pay = pay or EMPTY
			return nil, self.offer, self.winner_pay
		end
		self.winner_i, self.winner_offer, self.winner_pay = nil, nil, nil
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

			return nil, self.offer, self.winner_pay
		end

		npend = npend + 1
		pend[npend] = w
	end

	-- Clear trailing scratch.
	for i = npend + 1, #pend do pend[i] = nil end

	local w = wait_any(pend, npend)
	self._wait = w
	return w, nil, nil
end

function ChoiceOp:_pending_waitable()
	local w = self._wait
	if w then return w end

	-- preview() returns (waitable|nil, offer, payload); assigning captures the first result.
	local ww = self:preview()
	return ww or RETRY
end

function ChoiceOp:commit(expected_offer)
	if self.done then
		return nil, self.done_pay or EMPTY
	end

	if expected_offer ~= self.offer or not self.winner_i then
		return self:_pending_waitable(), nil
	end

	local wi   = self.winner_i
	local woff = self.winner_offer

	local w, committed = self.ops[wi]:commit(woff)
	if w then
		self.winner_i, self.winner_offer, self.winner_pay = nil, nil, nil
		return self:_pending_waitable(), nil
	end

	for i = 1, self.n do
		if i ~= wi then
			self.ops[i]:abort()
		end
	end

	self.done     = true
	self.done_pay = committed or self.winner_pay or EMPTY
	self._wait    = nil
	return nil, self.done_pay
end

function ChoiceOp:abort(_offer)
	if self.done then return end
	for i = 1, self.n do
		self.ops[i]:abort()
	end
	self.done = true
	self.done_pay = nil
	self._wait = nil
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
		out_pay   = { n = #ops }, -- reused (out_pay[i] is packed payload)

		done = false,

		_pend = {}, -- scratch waitables
		_wait = nil, -- last computed waitable when pending
	}, AllOp)
end

function AllOp:preview()
	if self.done then
		self._wait = nil
		return nil, self.offer, self.out_pay
	end

	self._wait = nil

	local pend = self._pend
	local npend = 0

	-- Attempt to preview all arms; if any pending, roll back prepared offers.
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
		-- Roll back any observed reservations.
		for i = 1, self.n do
			local off = self.arm_offer[i]
			if off ~= nil then
				self.ops[i]:abort(off)
				self.arm_offer[i] = nil
				self.out_pay[i]   = nil
			end
		end
		self.prepared = false

		-- Clear trailing scratch.
		for i = npend + 1, #pend do pend[i] = nil end

		local w = wait_any(pend, npend)
		self._wait = w
		return w, nil, nil
	end

	-- All ready.
	for i = npend + 1, #pend do pend[i] = nil end

	self.offer = self.offer + 1
	self.prepared = true
	self.out_pay.n = self.n
	return nil, self.offer, self.out_pay
end

function AllOp:_pending_waitable()
	local w = self._wait
	if w then return w end
	local ww = self:preview()
	return ww or RETRY
end

function AllOp:commit(expected_offer)
	if self.done then
		return nil, self.out_pay
	end

	if (not self.prepared) or expected_offer ~= self.offer then
		return self:_pending_waitable(), nil
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

			return self:_pending_waitable(), nil
		end
		self.out_pay[i] = pay or self.out_pay[i] or EMPTY
	end

	for i = 1, self.n do
		self.arm_offer[i] = nil
	end

	self.prepared = false
	self.done = true
	self._wait = nil
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
	self._wait = nil
end

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

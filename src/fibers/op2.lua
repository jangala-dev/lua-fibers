-- fibers/op2.lua
--
-- Transactional ops for event-driven, canonical-state (“LED”) primitives.
--
-- Ticket protocol (fixed-arity, internal) using integer tags:
--
--   preview(ctx) -> tag, proposal, payload_pack, pulse
--       tag = TAG_PENDING   => pulse is the pulse to watch; proposal/payload_pack nil
--       tag = TAG_PREVIEW   => proposal is opaque; payload_pack is {n=...,...}; pulse is canonical
--       tag = TAG_CANCELLED => all nil except tag
--
--   commit(ctx)  -> tag, proposal, payload_pack, pulse
--       tag = TAG_PENDING   => pulse is the pulse to watch; proposal/payload_pack nil
--       tag = TAG_DONE      => proposal is opaque; payload_pack is {n=...,...}; pulse nil
--       tag = TAG_CANCELLED => all nil except tag
--
-- perform(op) returns the payload values (unpacked from payload_pack) for a TAG_DONE result.
--
-- Performance choices:
--   * Allocation-free pulse subscription: caller-supplied intrusive nodes (no Token)
--   * Preallocated watches/tasks for composites (watch node is the scheduled task)
--   * No gate pulse; direct ctx.gate_state checks
--   * Fixed-arity ticket returns to keep perform() hot path free of pack()

---@module 'fibers.op2'

local runtime = require 'fibers.runtime'

local unpack = rawget(table, 'unpack') or _G.unpack
local pack   = rawget(table, 'pack') or function (...) return { n = select('#', ...), ... } end

local Op -- forward declaration for metatable checks

----------------------------------------------------------------------
-- Tag constants (integers)
----------------------------------------------------------------------

local TAG_PENDING   = 'tag_pending'
local TAG_PREVIEW   = 'tag_preview'
local TAG_DONE      = 'tag_done'
local TAG_CANCELLED = 'tag_cancelled'

----------------------------------------------------------------------
-- Phase constants for composite tickets
----------------------------------------------------------------------

local PH_OPEN      = 'phase_open'
local PH_CANCELLED = 'phase_cancelled'
local PH_DONE      = 'phase_done'

----------------------------------------------------------------------
-- Gate state constants (integers; stored directly on ctx)
----------------------------------------------------------------------

local GATE_OPEN       = 'gate_open'
local GATE_COMMITTING = 'gate_committing'
local GATE_ABORTED    = 'gate_aborted'

----------------------------------------------------------------------
-- Pulse: epoch + intrusive subscriber list (allocation-free subscribe)
----------------------------------------------------------------------

---@class Pulse
---@field _epoch integer
---@field _subs table|nil
local Pulse = {}
Pulse.__index = Pulse

---@return Pulse
local function new_pulse()
	return setmetatable({ _epoch = 0, _subs = nil }, Pulse)
end

---@return integer
function Pulse:now()
	return self._epoch
end

-- Intrusive node unlink (node is caller-owned).
local function node_unlink(node)
	if not node or not node._linked then return end
	node._linked = false

	local p = node._pulse
	if not p then
		node._prev, node._next = nil, nil
		return
	end

	local prev = node._prev
	local next = node._next

	if prev then
		prev._next = next
	else
		if p._subs == node then p._subs = next end
	end
	if next then next._prev = prev end

	node._pulse, node._prev, node._next = nil, nil, nil
end

--- Signal progress. One-shot: schedule and clear current subscribers. Must not yield.
function Pulse:signal()
	self._epoch = self._epoch + 1

	local sub = self._subs
	self._subs = nil

	while sub do
		local nxt = sub._next

		-- detach from this pulse
		sub._linked = false
		sub._pulse  = nil
		sub._prev   = nil
		sub._next   = nil

		-- schedule task (task/waker are node-owned, stable)
		local task  = sub._task
		local waker = sub._waker
		if task and waker then
			waker:schedule(task)
		end

		sub = nxt
	end
end

--- Subscribe node for “epoch advanced beyond seen_epoch”.
--- Allocation-free: node is supplied by caller and may be reused.
--- Invariant: node._task and node._waker are set once by the owner.
---@param seen_epoch integer
---@param node table
---@return boolean linked  # true if linked; false if scheduled immediately
function Pulse:subscribe_node(seen_epoch, node)
	-- ensure node is not linked elsewhere
	node_unlink(node)

	local waker = node._waker
	local task  = node._task
	if not waker or not task then
		error('Pulse.subscribe_node: node missing _waker/_task', 2)
	end

	if self._epoch > seen_epoch then
		waker:schedule(task)
		return false
	end

	-- link at head
	node._pulse  = self
	node._prev   = nil
	node._next   = self._subs
	node._linked = true
	if self._subs then self._subs._prev = node end
	self._subs = node

	return true
end

-- Fast-path alias (avoid method lookup at call-sites).
local pulse_subscribe = Pulse.subscribe_node

----------------------------------------------------------------------
-- Blocking on a pulse (root-only policy)
----------------------------------------------------------------------

-- Shared block function: no per-wait closure allocation.
local function block_subscribe_to_pulse(_, _, pulse, seen_epoch, node)
	pulse:subscribe_node(seen_epoch, node)
end

---@param ctx table
---@param pulse Pulse
local function block_on_pulse(ctx, pulse)
	local seen = pulse._epoch
	runtime.suspend(block_subscribe_to_pulse, pulse, seen, ctx._wait_node)
end

----------------------------------------------------------------------
-- Safe helpers for cancellation / abort hooks
----------------------------------------------------------------------

local function safe_cancel(t, ctx)
	local c = t and t.cancel
	if type(c) == 'function' then
		pcall(c, t, ctx)
	end
end

local function post_abort_then_cancel(t, ctx)
	if t and t._post_commit_abort then
		pcall(t._post_commit_abort, t, ctx)
	end
	safe_cancel(t, ctx)
end

----------------------------------------------------------------------
-- Watches: intrusive subscription nodes; the watch node is the scheduled task
----------------------------------------------------------------------

---@class Watch : Task
---@field owner any
---@field watched Pulse|nil
---@field _pulse Pulse|nil
---@field _prev Watch|nil
---@field _next Watch|nil
---@field _linked boolean
---@field _task any
---@field _waker any
local Watch = {}
Watch.__index = Watch

function Watch:run()
	self.owner._pulse:signal()
end

---@param owner any
---@param waker any
---@return Watch
local function watch_new(owner, waker)
	local w = setmetatable({
		owner   = owner,
		watched = nil,

		_pulse  = nil,
		_prev   = nil,
		_next   = nil,
		_linked = false,

		_task   = nil,  -- set below
		_waker  = waker,
	}, Watch)

	-- Invariant: a watch schedules itself.
	w._task = w
	return w
end

local function watch_clear(w)
	if not w then return end
	node_unlink(w)
	w.watched = nil
end

local function watch_set(w, pulse)
	if w.watched ~= pulse then
		node_unlink(w)
		w.watched = pulse
	end
	if not w._linked then
		pulse_subscribe(pulse, pulse._epoch, w)
	end
end

----------------------------------------------------------------------
-- Always/Never tickets
----------------------------------------------------------------------

-- ready ticket (constant payload)
local AlwaysTicket = {}
AlwaysTicket.__index = AlwaysTicket

function AlwaysTicket:pulse() return self._pulse end

function AlwaysTicket:preview(_ctx)
	return TAG_PREVIEW, self._proposal, self._payload, self._pulse
end

function AlwaysTicket:commit(ctx)
	if ctx.gate_state == GATE_ABORTED then return TAG_CANCELLED, nil, nil, nil end
	if ctx.gate_state ~= GATE_COMMITTING then return TAG_CANCELLED, nil, nil, nil end
	return TAG_DONE, self._proposal, self._payload, nil
end

function AlwaysTicket:cancel(_ctx) end


-- pending ticket (never becomes ready)
local NeverTicket = {}
NeverTicket.__index = NeverTicket

function NeverTicket:pulse() return self._pulse end

function NeverTicket:preview(_ctx)
	return TAG_PENDING, nil, nil, self._pulse
end

function NeverTicket:commit(ctx)
	if ctx.gate_state == GATE_ABORTED then return TAG_CANCELLED, nil, nil, nil end
	if ctx.gate_state ~= GATE_COMMITTING then return TAG_CANCELLED, nil, nil, nil end
	return TAG_PENDING, nil, nil, self._pulse
end

function NeverTicket:cancel(_ctx) end

----------------------------------------------------------------------
-- Wrapper tickets: wrap / finally / on_abort
----------------------------------------------------------------------

local EMPTY = { n = 0 }

---@class WrapTicket
---@field inner table
---@field f fun(...): ...
---@field _cache_p any|nil
---@field _cache_payload table|nil   -- payload_pack
local WrapTicket = {}
WrapTicket.__index = WrapTicket

function WrapTicket:pulse() return self.inner:pulse() end

function WrapTicket:preview(ctx)
	local tag, p, payload, pulse = self.inner:preview(ctx)
	if tag ~= TAG_PREVIEW then
		return tag, nil, nil, pulse
	end

	if self._cache_payload and self._cache_p == p then
		return TAG_PREVIEW, p, self._cache_payload, pulse
	end

	local ok, out = pcall(function ()
		return pack(self.f(unpack(payload, 1, payload.n)))
	end)
	if not ok then error(out, 0) end

	self._cache_p = p
	self._cache_payload = out
	return TAG_PREVIEW, p, out, pulse
end

function WrapTicket:commit(ctx)
	local tag, p, payload, pulse = self.inner:commit(ctx)

	if tag ~= TAG_DONE then
		return tag, nil, nil, pulse
	end

	-- Stronger invariant: commit follows a preview that produced the same proposal.
	if self._cache_p ~= p or not self._cache_payload then
		error('WrapTicket: commit proposal without cached preview mapping', 0)
	end

	return TAG_DONE, p, self._cache_payload, nil
end

function WrapTicket:cancel(ctx) safe_cancel(self.inner, ctx) end
function WrapTicket:_post_commit_abort(ctx)
	if self.inner and self.inner._post_commit_abort then
		self.inner:_post_commit_abort(ctx)
	end
end

---@class FinallyTicket
---@field inner table
---@field cleanup fun(aborted:boolean)
---@field _ran boolean
local FinallyTicket = {}
FinallyTicket.__index = FinallyTicket

function FinallyTicket:pulse() return self.inner:pulse() end

function FinallyTicket:_run(aborted)
	if self._ran then return end
	self._ran = true
	pcall(self.cleanup, aborted)
end

function FinallyTicket:preview(ctx)
	return self.inner:preview(ctx)
end

function FinallyTicket:commit(ctx)
	local tag, p, payload, pulse = self.inner:commit(ctx)
	if tag == TAG_DONE then
		self:_run(false)
	end
	return tag, p, payload, pulse
end

function FinallyTicket:cancel(ctx)
	safe_cancel(self.inner, ctx)
	self:_run(true)
end

function FinallyTicket:_post_commit_abort(ctx)
	if self.inner and self.inner._post_commit_abort then
		self.inner:_post_commit_abort(ctx)
	end
	self:_run(true)
end

---@class AbortTicket
---@field inner table
---@field abort_fn fun()
---@field _ran boolean
local AbortTicket = {}
AbortTicket.__index = AbortTicket

function AbortTicket:pulse() return self.inner:pulse() end
function AbortTicket:preview(ctx) return self.inner:preview(ctx) end
function AbortTicket:commit(ctx) return self.inner:commit(ctx) end
function AbortTicket:cancel(ctx) safe_cancel(self.inner, ctx) end

function AbortTicket:_post_commit_abort(ctx)
	if self.inner and self.inner._post_commit_abort then
		self.inner:_post_commit_abort(ctx)
	end
	if not self._ran then
		self._ran = true
		pcall(self.abort_fn)
	end
end

----------------------------------------------------------------------
-- Composite: all(...)
-- Semantics preserved: returns ONE value (a table of payload packs).
----------------------------------------------------------------------

---@class AllTicket
---@field _pulse Pulse
---@field kids table[]
---@field watch Watch[]
---@field prepared_p any[]
---@field prepared_vals table[]         -- payload packs per child
---@field prepared_results table        -- reused array of payload packs
---@field prepared_payload table        -- payload pack of size 1: {n=1, [1]=prepared_results}
---@field nonce integer                 -- monotonic version (proposal identity source)
---@field prepared_nonce integer|nil    -- proposal for current ready snapshot
---@field phase integer
local AllTicket = {}
AllTicket.__index = AllTicket

function AllTicket:pulse() return self._pulse end

function AllTicket:_clear_watches()
	for i = 1, #self.watch do
		watch_clear(self.watch[i])
	end
end

function AllTicket:_invalidate_prepared()
	-- Only needs to change if we have issued a proposal.
	if self.prepared_nonce ~= nil then
		self.nonce = self.nonce + 1
		self.prepared_nonce = nil
	end
end

function AllTicket:preview(ctx)
	if self.phase == PH_CANCELLED then return TAG_CANCELLED, nil, nil, nil end
	if self.phase == PH_DONE then
		return TAG_PREVIEW, self.prepared_nonce, self.prepared_payload, self._pulse
	end

	local n = #self.kids
	local all_ready = true

	for i = 1, n do
		local kid = self.kids[i]
		local tag, prop, payload, wpulse = kid:preview(ctx)
		local w = self.watch[i]

		if tag == TAG_PENDING then
			all_ready = false
			if self.prepared_p[i] ~= nil then
				self.prepared_p[i] = nil
				self.prepared_vals[i] = nil
				self:_invalidate_prepared()
			end
			watch_set(w, wpulse)

		elseif tag == TAG_PREVIEW then
			if self.prepared_p[i] ~= prop then
				self.prepared_p[i] = prop
				self:_invalidate_prepared()
			end
			self.prepared_vals[i] = payload
			watch_set(w, wpulse or kid:pulse())

		elseif tag == TAG_CANCELLED then
			self.phase = PH_CANCELLED
			return TAG_CANCELLED, nil, nil, nil

		else
			error('all: invalid child status in preview', 0)
		end
	end

	if not all_ready then
		return TAG_PENDING, nil, nil, self._pulse
	end

	if self.prepared_nonce == nil then
		-- Establish a new snapshot proposal.
		self.prepared_nonce = self.nonce
		for i = 1, n do
			self.prepared_results[i] = self.prepared_vals[i]
		end
	end

	return TAG_PREVIEW, self.prepared_nonce, self.prepared_payload, self._pulse
end

function AllTicket:commit(ctx)
	if self.phase == PH_CANCELLED then return TAG_CANCELLED, nil, nil, nil end
	if ctx.gate_state == GATE_ABORTED then return TAG_CANCELLED, nil, nil, nil end
	if self.phase == PH_DONE then
		return TAG_DONE, self.prepared_nonce, self.prepared_payload, nil
	end
	if ctx.gate_state ~= GATE_COMMITTING then
		return TAG_CANCELLED, nil, nil, nil
	end

	if self.prepared_nonce == nil then return TAG_CANCELLED, nil, nil, nil end
	for i = 1, #self.kids do
		if self.prepared_p[i] == nil then return TAG_CANCELLED, nil, nil, nil end
	end

	for i = 1, #self.kids do
		local kid = self.kids[i]
		local tag, prop, _payload, wpulse = kid:commit(ctx)
		local w = self.watch[i]

		if tag == TAG_PENDING then
			watch_set(w, wpulse)
			return TAG_PENDING, nil, nil, self._pulse

		elseif tag == TAG_DONE then
			if prop ~= self.prepared_p[i] then return TAG_CANCELLED, nil, nil, nil end

		elseif tag == TAG_CANCELLED then
			return TAG_CANCELLED, nil, nil, nil

		else
			error('all: invalid child status in commit', 0)
		end
	end

	self.phase = PH_DONE
	self:_clear_watches()
	return TAG_DONE, self.prepared_nonce, self.prepared_payload, nil
end

function AllTicket:cancel(ctx)
	if self.phase == PH_CANCELLED then return end
	self.phase = PH_CANCELLED
	self:_clear_watches()
	for i = 1, #self.kids do
		safe_cancel(self.kids[i], ctx)
	end
end

function AllTicket:_post_commit_abort(ctx)
	for i = 1, #self.kids do
		local k = self.kids[i]
		if k and k._post_commit_abort then k:_post_commit_abort(ctx) end
	end
end

----------------------------------------------------------------------
-- Composite: choice(...)
----------------------------------------------------------------------

---@class ChoiceTicket
---@field _pulse Pulse
---@field arms table[]
---@field watch Watch[]
---@field dead boolean[]
---@field prepared_i integer|nil
---@field prepared_p any|nil
---@field prepared_vals table|nil     -- payload pack
---@field phase integer
local ChoiceTicket = {}
ChoiceTicket.__index = ChoiceTicket

function ChoiceTicket:pulse() return self._pulse end

function ChoiceTicket:_clear_watches()
	for i = 1, #self.watch do
		watch_clear(self.watch[i])
	end
end

function ChoiceTicket:_withdraw_prepared()
	self.prepared_i    = nil
	self.prepared_p    = nil
	self.prepared_vals = nil
end

function ChoiceTicket:preview(ctx)
	if self.phase == PH_CANCELLED then return TAG_CANCELLED, nil, nil, nil end
	if self.phase == PH_DONE then
		return TAG_PREVIEW, self.prepared_p, self.prepared_vals, self._pulse
	end

	local n = #self.arms
	local gate_state = ctx.gate_state

	-- Validate cached winner while gate is still open.
	if self.prepared_i and gate_state == GATE_OPEN and not self.dead[self.prepared_i] then
		local i = self.prepared_i
		local arm = self.arms[i]
		local tag, prop, _payload, wpulse = arm:preview(ctx)

		if tag == TAG_PREVIEW and prop == self.prepared_p then
			watch_set(self.watch[i], wpulse or arm:pulse())
			return TAG_PREVIEW, self.prepared_p, self.prepared_vals, self._pulse
		end

		self:_withdraw_prepared()
	end

	local any_pending = false
	local any_alive = false

	for i = 1, n do
		if not self.dead[i] then
			any_alive = true

			local arm = self.arms[i]
			local tag, prop, payload, wpulse = arm:preview(ctx)
			local w = self.watch[i]

			if tag == TAG_PENDING then
				any_pending = true
				watch_set(w, wpulse)

			elseif tag == TAG_PREVIEW then
				watch_set(w, wpulse or arm:pulse())
				if not self.prepared_i then
					self.prepared_i    = i
					self.prepared_p    = prop
					self.prepared_vals = payload
				end

			elseif tag == TAG_CANCELLED then
				self.dead[i] = true
				watch_clear(w)
				safe_cancel(arm, ctx)

			else
				error('choice: invalid arm status in preview', 0)
			end
		end
	end

	if self.prepared_i then
		return TAG_PREVIEW, self.prepared_p, self.prepared_vals, self._pulse
	end

	if any_pending or any_alive then
		return TAG_PENDING, nil, nil, self._pulse
	end

	self.phase = PH_CANCELLED
	return TAG_CANCELLED, nil, nil, nil
end

function ChoiceTicket:commit(ctx)
	if self.phase == PH_CANCELLED then return TAG_CANCELLED, nil, nil, nil end
	if ctx.gate_state == GATE_ABORTED then return TAG_CANCELLED, nil, nil, nil end
	if self.phase == PH_DONE then
		return TAG_DONE, self.prepared_p, self.prepared_vals, nil
	end
	if ctx.gate_state ~= GATE_COMMITTING then
		return TAG_CANCELLED, nil, nil, nil
	end

	local i = self.prepared_i
	if not i or self.dead[i] then
		return TAG_CANCELLED, nil, nil, nil
	end

	local winner = self.arms[i]
	local tag, prop, payload, wpulse = winner:commit(ctx)
	local w = self.watch[i]

	if tag == TAG_PENDING then
		watch_set(w, wpulse)
		return TAG_PENDING, nil, nil, self._pulse

	elseif tag == TAG_DONE then
		if prop ~= self.prepared_p then return TAG_CANCELLED, nil, nil, nil end
		self.prepared_vals = payload

		for j = 1, #self.arms do
			if j ~= i and not self.dead[j] then
				post_abort_then_cancel(self.arms[j], ctx)
				self.dead[j] = true
			end
		end

		self.phase = PH_DONE
		self:_clear_watches()
		return TAG_DONE, self.prepared_p, self.prepared_vals, nil

	elseif tag == TAG_CANCELLED then
		return TAG_CANCELLED, nil, nil, nil
	end

	error('choice: invalid winner status in commit', 0)
end

function ChoiceTicket:cancel(ctx)
	if self.phase == PH_CANCELLED then return end
	self.phase = PH_CANCELLED
	self:_clear_watches()
	for i = 1, #self.arms do
		safe_cancel(self.arms[i], ctx)
	end
end

function ChoiceTicket:_post_commit_abort(ctx)
	for i = 1, #self.arms do
		local a = self.arms[i]
		if a and a._post_commit_abort then a:_post_commit_abort(ctx) end
	end
end

----------------------------------------------------------------------
-- Composite: and_then (LHS proposal identity drives RHS rebuild)
----------------------------------------------------------------------

---@class AndThenTicket
---@field _pulse Pulse
---@field left table
---@field right table|nil
---@field k fun(...): any
---@field prepared_left_p any|nil
---@field prepared_right_p any|nil
---@field prepared_right_vals table|nil  -- payload pack
---@field left_watch Watch
---@field right_watch Watch
---@field phase integer
local AndThenTicket = {}
AndThenTicket.__index = AndThenTicket

function AndThenTicket:pulse() return self._pulse end

function AndThenTicket:_invalidate_right(ctx)
	if self.right then safe_cancel(self.right, ctx) end
	self.right = nil
	self.prepared_right_p = nil
	self.prepared_right_vals = nil
	watch_clear(self.right_watch)
end

function AndThenTicket:preview(ctx)
	if self.phase == PH_CANCELLED then return TAG_CANCELLED, nil, nil, nil end
	if self.phase == PH_DONE then
		return TAG_PREVIEW, self.prepared_right_p, self.prepared_right_vals, self._pulse
	end

	local ltag, lprop, lpayload, lwpulse = self.left:preview(ctx)

	if ltag == TAG_PENDING then
		if self.prepared_left_p ~= nil then
			self.prepared_left_p = nil
			self:_invalidate_right(ctx)
		end
		watch_set(self.left_watch, lwpulse)
		return TAG_PENDING, nil, nil, self._pulse

	elseif ltag == TAG_CANCELLED then
		self.phase = PH_CANCELLED
		return TAG_CANCELLED, nil, nil, nil

	elseif ltag ~= TAG_PREVIEW then
		error('and_then: invalid left status in preview', 0)
	end

	if self.prepared_left_p ~= lprop then
		self.prepared_left_p = lprop
		self:_invalidate_right(ctx)

		local ok, op_or_err = pcall(self.k, unpack(lpayload, 1, lpayload.n))
		if not ok then error(op_or_err, 0) end
		if type(op_or_err) ~= 'table' or getmetatable(op_or_err) ~= Op then
			error('and_then: k must return an Op', 0)
		end

		self.right = op_or_err:_instantiate(ctx)
	end

	watch_set(self.left_watch, lwpulse or self.left:pulse())

	if not self.right then
		return TAG_PENDING, nil, nil, self._pulse
	end

	local rtag, rprop, rpayload, rwpulse = self.right:preview(ctx)

	if rtag == TAG_PENDING then
		self.prepared_right_p = nil
		self.prepared_right_vals = nil
		watch_set(self.right_watch, rwpulse)
		return TAG_PENDING, nil, nil, self._pulse

	elseif rtag == TAG_PREVIEW then
		self.prepared_right_p = rprop
		self.prepared_right_vals = rpayload
		watch_set(self.right_watch, rwpulse or self.right:pulse())
		return TAG_PREVIEW, self.prepared_right_p, self.prepared_right_vals, self._pulse

	elseif rtag == TAG_CANCELLED then
		self.phase = PH_CANCELLED
		return TAG_CANCELLED, nil, nil, nil
	end

	error('and_then: invalid right status in preview', 0)
end

function AndThenTicket:commit(ctx)
	if self.phase == PH_CANCELLED then return TAG_CANCELLED, nil, nil, nil end
	if ctx.gate_state == GATE_ABORTED then return TAG_CANCELLED, nil, nil, nil end
	if self.phase == PH_DONE then
		return TAG_DONE, self.prepared_right_p, self.prepared_right_vals, nil
	end
	if ctx.gate_state ~= GATE_COMMITTING then
		return TAG_CANCELLED, nil, nil, nil
	end

	if not self.prepared_left_p or not self.right or not self.prepared_right_p then
		return TAG_CANCELLED, nil, nil, nil
	end

	local ltag, lprop, _lpayload, lwpulse = self.left:commit(ctx)
	if ltag == TAG_PENDING then
		watch_set(self.left_watch, lwpulse)
		return TAG_PENDING, nil, nil, self._pulse
	elseif ltag == TAG_DONE then
		if lprop ~= self.prepared_left_p then return TAG_CANCELLED, nil, nil, nil end
	elseif ltag == TAG_CANCELLED then
		return TAG_CANCELLED, nil, nil, nil
	else
		error('and_then: invalid left status in commit', 0)
	end

	local rtag, rprop, rpayload, rwpulse = self.right:commit(ctx)
	if rtag == TAG_PENDING then
		watch_set(self.right_watch, rwpulse)
		return TAG_PENDING, nil, nil, self._pulse
	elseif rtag == TAG_DONE then
		if rprop ~= self.prepared_right_p then return TAG_CANCELLED, nil, nil, nil end
		self.prepared_right_vals = rpayload
		self.phase = PH_DONE
		watch_clear(self.left_watch)
		watch_clear(self.right_watch)
		return TAG_DONE, self.prepared_right_p, self.prepared_right_vals, nil
	elseif rtag == TAG_CANCELLED then
		return TAG_CANCELLED, nil, nil, nil
	end

	error('and_then: invalid right status in commit', 0)
end

function AndThenTicket:cancel(ctx)
	if self.phase == PH_CANCELLED then return end
	self.phase = PH_CANCELLED
	watch_clear(self.left_watch)
	watch_clear(self.right_watch)
	if self.right then safe_cancel(self.right, ctx) end
	safe_cancel(self.left, ctx)
end

function AndThenTicket:_post_commit_abort(ctx)
	if self.right and self.right._post_commit_abort then self.right:_post_commit_abort(ctx) end
	if self.left and self.left._post_commit_abort then self.left:_post_commit_abort(ctx) end
end

----------------------------------------------------------------------
-- Op representation and instantiation
----------------------------------------------------------------------

Op = {}
Op.__index = Op

local function is_op(x) return type(x) == 'table' and getmetatable(x) == Op end
local function assert_op(x, where)
	if not is_op(x) then error(where .. ' expects an Op', 3) end
end

function Op:_instantiate(ctx)
	local k = self.kind

	if k == 'prim' then
		return self.start_fn(ctx)

	elseif k == 'guard' then
		local opv = self.thunk()
		if not is_op(opv) then error('guard: thunk must return an Op', 0) end
		return opv:_instantiate(ctx)

	elseif k == 'wrap' then
		return setmetatable({ inner = self.inner:_instantiate(ctx), f = self.f }, WrapTicket)

	elseif k == 'finally' then
		return setmetatable({ inner = self.inner:_instantiate(ctx), cleanup = self.f, _ran = false }, FinallyTicket)

	elseif k == 'abort' then
		return setmetatable({ inner = self.inner:_instantiate(ctx), abort_fn = self.f, _ran = false }, AbortTicket)

	elseif k == 'all' then
		local kids = {}
		for i = 1, #self.ops do kids[i] = self.ops[i]:_instantiate(ctx) end

		local owner = {
			_pulse = new_pulse(),
			kids   = kids,

			watch  = {},

			prepared_p    = {},
			prepared_vals = {},

			-- reused containers
			prepared_results = {},
			prepared_payload  = { n = 1, nil },

			nonce          = 0,
			prepared_nonce = nil,

			phase = PH_OPEN,
		}

		owner.prepared_payload[1] = owner.prepared_results

		-- preallocate watches (watch node is its own scheduled task)
		local waker = ctx.scheduler
		for i = 1, #kids do
			owner.watch[i] = watch_new(owner, waker)
		end

		return setmetatable(owner, AllTicket)

	elseif k == 'choice' then
		local arms = {}
		for i = 1, #self.ops do arms[i] = self.ops[i]:_instantiate(ctx) end

		local owner = {
			_pulse = new_pulse(),
			arms   = arms,

			watch  = {},
			dead   = {},

			prepared_i    = nil,
			prepared_p    = nil,
			prepared_vals = nil,

			phase = PH_OPEN,
		}

		-- preallocate watches
		local waker = ctx.scheduler
		for i = 1, #arms do
			owner.watch[i] = watch_new(owner, waker)
		end

		return setmetatable(owner, ChoiceTicket)

	elseif k == 'and_then' then
		local owner = {
			_pulse = new_pulse(),
			left   = self.inner:_instantiate(ctx),
			right  = nil,
			k      = self.k,

			prepared_left_p     = nil,
			prepared_right_p    = nil,
			prepared_right_vals = nil,

			left_watch  = nil,
			right_watch = nil,

			phase = PH_OPEN,
		}

		-- preallocate watches
		local waker = ctx.scheduler
		owner.left_watch  = watch_new(owner, waker)
		owner.right_watch = watch_new(owner, waker)

		return setmetatable(owner, AndThenTicket)

	else
		error('unknown op kind: ' .. tostring(k), 0)
	end
end

----------------------------------------------------------------------
-- Public constructors
----------------------------------------------------------------------

---@param start_fn fun(ctx: table): table
---@return Op
local function new_primitive(start_fn)
	if type(start_fn) ~= 'function' then error('new_primitive: start_fn must be a function', 2) end
	return setmetatable({ kind = 'prim', start_fn = start_fn }, Op)
end

---@param ... Op
---@return Op
local function choice(...)
	local ops = { ... }
	if #ops == 0 then error('choice expects at least one op', 2) end
	for i = 1, #ops do assert_op(ops[i], 'choice') end
	if #ops == 1 then return ops[1] end
	return setmetatable({ kind = 'choice', ops = ops }, Op)
end

---@param ... Op
---@return Op
local function all(...)
	local ops = { ... }
	if #ops == 0 then error('all expects at least one op', 2) end
	for i = 1, #ops do assert_op(ops[i], 'all') end
	if #ops == 1 then return ops[1] end
	return setmetatable({ kind = 'all', ops = ops }, Op)
end

---@param thunk fun(): Op
---@return Op
local function guard(thunk)
	if type(thunk) ~= 'function' then error('guard expects a function', 2) end
	return setmetatable({ kind = 'guard', thunk = thunk }, Op)
end

---@param ... any
---@return Op
local function always(...)
	local payload = pack(...)
	return new_primitive(function (_ctx)
		return setmetatable({
			_pulse    = new_pulse(),
			_proposal = 1,        -- any stable identity is fine here
			_payload  = payload,
		}, AlwaysTicket)
	end)
end

---@return Op
local function never()
	return new_primitive(function (_ctx)
		return setmetatable({
			_pulse = new_pulse(),
		}, NeverTicket)
	end)
end

---@param acquire fun(): any
---@param release fun(resource:any, aborted:boolean)
---@param use fun(resource:any): Op
---@return Op
local function bracket(acquire, release, use)
	if type(acquire) ~= 'function' then error('bracket: acquire must be a function', 2) end
	if type(release) ~= 'function' then error('bracket: release must be a function', 2) end
	if type(use) ~= 'function' then error('bracket: use must be a function', 2) end

	return guard(function ()
		local res = acquire()
		local opv = use(res)
		if not is_op(opv) then error('bracket: use must return an Op', 0) end
		return opv:finally(function (aborted)
			pcall(release, res, aborted)
		end)
	end)
end

function Op:wrap(f)
	if type(f) ~= 'function' then error('wrap expects a function', 2) end
	return setmetatable({ kind = 'wrap', inner = self, f = f }, Op)
end

function Op:and_then(k)
	if type(k) ~= 'function' then error('and_then expects a function', 2) end
	return setmetatable({ kind = 'and_then', inner = self, k = k }, Op)
end

function Op:on_abort(f)
	if type(f) ~= 'function' then error('on_abort expects a function', 2) end
	return setmetatable({ kind = 'abort', inner = self, f = f }, Op)
end

function Op:finally(cleanup)
	if type(cleanup) ~= 'function' then error('finally expects a function', 2) end
	return setmetatable({ kind = 'finally', inner = self, f = cleanup }, Op)
end

----------------------------------------------------------------------
-- perform(op): attempt loop (no pack() in the hot path)
----------------------------------------------------------------------

local function perform(opv)
	if not runtime.current_fiber() then
		error('perform must be called from within a fibre', 2)
	end
	assert_op(opv, 'perform')

	local scheduler = runtime.current_scheduler
	local fib = runtime.current_fiber()

	-- Root context. One wait node reused for all root pulse blocks in this perform().
	local ctx = {
		gate_state = GATE_OPEN,
		scheduler  = scheduler,

		_wait_node = {
			_linked = false,
			_task   = fib,       -- schedule the fibre directly
			_waker  = scheduler, -- stable for this runtime
		},
	}

	while true do
		ctx.gate_state = GATE_OPEN

		local root = opv:_instantiate(ctx)

		-- Preview until proposal or cancellation.
		local cancelled = false
		while true do
			local tag, _p, _payload, pulse = root:preview(ctx)
			if tag == TAG_PREVIEW then
				break
			elseif tag == TAG_PENDING then
				block_on_pulse(ctx, pulse)
			elseif tag == TAG_CANCELLED then
				cancelled = true
				break
			else
				error('perform: invalid root status in preview', 0)
			end
		end

		if cancelled then
			ctx.gate_state = GATE_ABORTED
			safe_cancel(root, ctx)
		else
			ctx.gate_state = GATE_COMMITTING

			-- Commit until done or cancellation; yield once on first pending.
			local yielded_once = false
			while true do
				local tag, _p, payload, pulse = root:commit(ctx)

				if tag == TAG_DONE then
					if not payload or payload.n == 0 then return end
					return unpack(payload, 1, payload.n)

				elseif tag == TAG_PENDING then
					if not yielded_once then
						yielded_once = true
						runtime.yield()
					else
						block_on_pulse(ctx, pulse)
					end

				elseif tag == TAG_CANCELLED then
					ctx.gate_state = GATE_ABORTED
					safe_cancel(root, ctx)
					break -- retry attempt

				else
					error('perform: invalid root status in commit', 0)
				end
			end
		end
	end
end

return {
	perform       = perform,

	new_primitive = new_primitive,
	choice        = choice,
	all           = all,
	guard         = guard,
	always        = always,
	never         = never,
	bracket       = bracket,

	Op            = Op,

	-- for primitive authors / tests
	Pulse         = Pulse,
	new_pulse     = new_pulse,

	-- tags
	TAG_PENDING   = TAG_PENDING,
	TAG_PREVIEW   = TAG_PREVIEW,
	TAG_DONE      = TAG_DONE,
	TAG_CANCELLED = TAG_CANCELLED,

	-- gate state constants
	GATE_OPEN       = GATE_OPEN,
	GATE_COMMITTING = GATE_COMMITTING,
	GATE_ABORTED    = GATE_ABORTED,

	-- pack helper for varargs payloads
	pack           = pack,
	EMPTY          = EMPTY,
}

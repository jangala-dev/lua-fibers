-- fibers/op2.lua
--
-- Transactional ops for cooperative fibres.
--
-- Overview
-- --------
-- An Op is a pure expression (a small algebra of combinators) which is executed by perform(op).
-- Execution is transactional: perform repeatedly asks the instantiated graph for a preview of
-- readiness, then commits that same preview.
--
-- Instantiation
-- -------------
-- perform(op) instantiates the Op once into a network of *tickets*. A ticket is the concrete
-- runtime object for a node in the op expression. Tickets are stateful but must obey the
-- preview/commit protocol below.
--
-- Ticket protocol (strict)
-- ------------------------
-- preview(ctx) -> tag, proposal, payload_pack, pulse
--   TAG_PENDING:
--     Not preview-ready. proposal/payload_pack are nil. pulse is a progress pulse to watch.
--   TAG_PREVIEW:
--     Preview-ready. proposal is an opaque identity for this preview snapshot. payload_pack is a
--     packed result table { n = ..., [1] = ..., ... }. pulse is a progress pulse (may be nil for
--     tickets that never block).
--   TAG_CANCELLED:
--     Terminal failure/cancellation. All other values nil.
--
-- commit(ctx, expected_proposal) -> tag, payload_pack, pulse
--   TAG_DONE:
--     Commit succeeded for expected_proposal. payload_pack is the committed result. pulse is nil.
--   TAG_PENDING:
--     Commit cannot yet reify expected_proposal (or the preview has been invalidated). pulse is a
--     progress pulse to watch; the caller will re-preview after waking.
--   TAG_CANCELLED:
--     Terminal failure/cancellation.
--
-- Core invariants
-- ---------------
-- 1) Proposal stability. A proposal returned by preview(ctx) is a claim about readiness at a
--    particular snapshot. commit(ctx, proposal) must *only* attempt to reify that proposal and
--    must not search for a different outcome.
--
-- 2) Invalidation by pulse. If a ticket has returned TAG_PREVIEW for proposal P, it is responsible
--    for signalling its pulse when that preview may no longer hold (including when P changes, or
--    when commit would newly return TAG_PENDING). Pulses are monotone epochs; signalling indicates
--    “the previously previewed snapshot may be stale”.
--
-- 3) Progress. After signalling the pulse, the ticket should eventually make progress such that a
--    subsequent preview/commit sequence can advance (or reach TAG_CANCELLED).
--
-- 4) Cancellation. cancel(ctx) is best-effort and idempotent; it must detach external interest and
--    signal any relevant pulses so blocked fibres can wake and observe cancellation.
--
-- perform(op) algorithm
-- ---------------------
-- perform drives the root ticket as:
--   PREVIEW:  loop calling preview until TAG_PREVIEW (blocking on pulse when TAG_PENDING).
--   COMMIT:   call commit with the returned proposal. If TAG_PENDING, block on pulse and retry
--             from PREVIEW; if TAG_DONE, return the unpacked payload; if TAG_CANCELLED, error.
--
-- Combinators
-- -----------
-- Composite ops (choice/all/choose_k/and_then) are built from a single select ticket with a policy.
-- Composite tickets maintain watches on child pulses; when any watched pulse signals, the composite
-- pulse signals, invalidating any cached plan and prompting a new preview scan.
--
-- Decoration
-- ----------
-- wrap/finally/on_abort are implemented as ticket annotations:
--   * wraps are applied to preview payloads and cached for the matching commit;
--   * finally runs once on success, and best-effort on cancellation/abort;
--   * on_abort runs best-effort when an arm loses after a competing commit.
--
---@module 'fibers.op2'

local runtime = require 'fibers.runtime'

local unpack = rawget(table, 'unpack') or _G.unpack
local pack   = rawget(table, 'pack') or function (...) return { n = select('#', ...), ... } end

local Op -- forward declaration for metatable checks

----------------------------------------------------------------------
-- Tag constants
----------------------------------------------------------------------

local TAG_PENDING   = 'tag_pending'
local TAG_PREVIEW   = 'tag_preview'
local TAG_DONE      = 'tag_done'
local TAG_CANCELLED = 'tag_cancelled'

----------------------------------------------------------------------
-- Phase constants for composite tickets
----------------------------------------------------------------------

local PH_OPEN      = 'phase_open'
local PH_ABORTED   = 'phase_aborted'
local PH_CANCELLED = 'phase_cancelled'
local PH_DONE      = 'phase_done'

----------------------------------------------------------------------
-- Gate state constants for primitive authors (stored on ctx)
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
	return setmetatable({ _epoch = 0 }, Pulse)
end

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

function Pulse:signal()
	self._epoch = self._epoch + 1

	local sub = self._subs
	self._subs = nil

	while sub do
		local nxt = sub._next

		sub._linked = false
		sub._pulse  = nil
		sub._prev   = nil
		sub._next   = nil

		local task  = sub._task
		local waker = sub._waker
		waker:schedule(task)

		sub = nxt
	end
end

function Pulse:subscribe_node(seen_epoch, node)
	node_unlink(node)

	if self._epoch > seen_epoch then
		node._waker:schedule(node._task)
		return false
	end

	node._pulse  = self
	node._prev   = nil
	node._next   = self._subs
	node._linked = true
	if self._subs then self._subs._prev = node end
	self._subs = node

	return true
end

local pulse_subscribe = Pulse.subscribe_node

----------------------------------------------------------------------
-- Blocking on a pulse (root-only policy)
----------------------------------------------------------------------

local function block_subscribe_to_pulse(_, _, pulse, seen_epoch, node)
	pulse:subscribe_node(seen_epoch, node)
end

---@param ctx table
---@param pulse Pulse
---@param seen_epoch? integer
local function block_on_pulse(ctx, pulse, seen_epoch)
	local seen = (seen_epoch ~= nil) and seen_epoch or pulse._epoch
	runtime.suspend(block_subscribe_to_pulse, pulse, seen, ctx._wait_node)
end

----------------------------------------------------------------------
-- Always/Never tickets
----------------------------------------------------------------------

local EMPTY = { n = 0 }

local AlwaysTicket = {}
AlwaysTicket.__index = AlwaysTicket

function AlwaysTicket:pulse() return nil end

function AlwaysTicket:preview(_ctx) return TAG_PREVIEW, self._proposal, self._payload, nil end

function AlwaysTicket:commit(_ctx, _expected_proposal) return TAG_DONE, self._payload, nil end

function AlwaysTicket:cancel(_ctx) end

local NeverTicket = {}
NeverTicket.__index = NeverTicket

function NeverTicket:pulse() return self._pulse end

function NeverTicket:preview(_ctx) return TAG_PENDING, nil, nil, self._pulse end

function NeverTicket:commit(_ctx, _expected_proposal) return TAG_PENDING, nil, self._pulse end

function NeverTicket:cancel(_ctx) end

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
		_linked = false,
		_waker  = waker,
	}, Watch)

	w._task = w
	return w
end

local function watch_clear(w)
	node_unlink(w)
	w.watched = nil
	w._seen_epoch = nil
end

local function watch_set(w, pulse)
	if pulse == nil then
		watch_clear(w)
		return
	end

	if w.watched ~= pulse then
		node_unlink(w)
		w.watched = pulse
	end

	w._seen_epoch = pulse._epoch

	if not w._linked then
		pulse_subscribe(pulse, w._seen_epoch, w)
	end
end

----------------------------------------------------------------------
-- Ticket decoration: wrap / finally / on_abort as annotations (metatable-based)
--
-- Tickets must have metatable __index as a *table* of methods.
----------------------------------------------------------------------

local function ann_is_empty(ann)
	if not ann then return true end
	return (not ann.wraps or #ann.wraps == 0)
		and (not ann.finallys or #ann.finallys == 0)
		and (not ann.aborts or #ann.aborts == 0)
end

local function ann_merge(a, b)
	if ann_is_empty(a) then return b end
	if ann_is_empty(b) then return a end

	local out = {}

	if a.wraps or b.wraps then
		local t = {}
		if a.wraps then for i = 1, #a.wraps do t[#t + 1] = a.wraps[i] end end
		if b.wraps then for i = 1, #b.wraps do t[#t + 1] = b.wraps[i] end end
		out.wraps = t
	end

	if a.finallys or b.finallys then
		local t = {}
		if a.finallys then for i = 1, #a.finallys do t[#t + 1] = a.finallys[i] end end
		if b.finallys then for i = 1, #b.finallys do t[#t + 1] = b.finallys[i] end end
		out.finallys = t
	end

	if a.aborts or b.aborts then
		local t = {}
		if a.aborts then for i = 1, #a.aborts do t[#t + 1] = a.aborts[i] end end
		if b.aborts then for i = 1, #b.aborts do t[#t + 1] = b.aborts[i] end end
		out.aborts = t
	end

	return out
end

local function apply_wraps(wraps, payload)
	local out = payload or EMPTY
	for i = 1, #wraps do
		out = pack(wraps[i](unpack(out, 1, out.n)))
	end
	return out
end

local function run_finallys_once(self, aborted)
	if rawget(self, '_ann_finally_ran') then return end
	rawset(self, '_ann_finally_ran', true)

	local ann = rawget(self, '_ann')
	local fs = ann and ann.finallys or nil
	if not fs then return end

	for i = 1, #fs do
		pcall(fs[i], aborted)
	end
end

local function run_aborts_once(self)
	if rawget(self, '_ann_abort_ran') then return end
	rawset(self, '_ann_abort_ran', true)

	local ann = rawget(self, '_ann')
	local as = ann and ann.aborts or nil
	if not as then return end

	for i = 1, #as do
		pcall(as[i])
	end
end

---@param ticket table
---@param add_ann table
---@return table
local function decorate_ticket(ticket, add_ann)
	if ann_is_empty(add_ann) then
		return ticket
	end

	local existing = rawget(ticket, '_ann')
	if existing then
		rawset(ticket, '_ann', ann_merge(existing, add_ann))
		rawset(ticket, '_ann_wrap_cache_p', nil)
		rawset(ticket, '_ann_wrap_cache_payload', nil)
	else
		rawset(ticket, '_ann', add_ann)
	end

	local mt = getmetatable(ticket) or {}
	if mt.__ann_decorated then
		return ticket
	end

	local base_index = mt.__index
	if type(base_index) ~= 'table' then
		error('decorate_ticket expects tickets with metatable __index table', 2)
	end

	local idx = {}
	setmetatable(idx, { __index = base_index })

	idx.preview = function (self, ctx)
		local tag, p, payload, pulse = base_index.preview(self, ctx)
		if tag ~= TAG_PREVIEW then
			return tag, nil, nil, pulse
		end

		local ann = rawget(self, '_ann')
		local wraps = ann and ann.wraps or nil
		if not wraps or #wraps == 0 then
			return TAG_PREVIEW, p, payload or EMPTY, pulse
		end

		local cache_p = rawget(self, '_ann_wrap_cache_p')
		if cache_p ~= p then
			local out = apply_wraps(wraps, payload)
			rawset(self, '_ann_wrap_cache_p', p)
			rawset(self, '_ann_wrap_cache_payload', out)
		end

		return TAG_PREVIEW, p, rawget(self, '_ann_wrap_cache_payload'), pulse
	end

	idx.commit = function (self, ctx, expected_proposal)
		local tag, payload, pulse = base_index.commit(self, ctx, expected_proposal)
		if tag == TAG_PENDING then
			return TAG_PENDING, nil, pulse
		elseif tag ~= TAG_DONE then
			return TAG_CANCELLED, nil, nil
		end

		-- If preview ran for this proposal, we already have the wrapped pack cached.
		local out = rawget(self, '_ann_wrap_cache_payload')
		if rawget(self, '_ann_wrap_cache_p') ~= expected_proposal or not out then
			-- Fallback: compute once if commit is called without a matching preview.
			local ann = rawget(self, '_ann')
			local wraps = ann and ann.wraps or nil
			out = payload or EMPTY
			if wraps and #wraps > 0 then
				out = apply_wraps(wraps, out)
				rawset(self, '_ann_wrap_cache_p', expected_proposal)
				rawset(self, '_ann_wrap_cache_payload', out)
			end
		end

		run_finallys_once(self, false)
		return TAG_DONE, out, nil
	end

	idx.cancel = function (self, ctx)
		base_index.cancel(self, ctx)
		run_finallys_once(self, true)
	end

	idx._post_commit_abort = function (self, ctx)
		local pa = base_index._post_commit_abort
		if pa then pa(self, ctx) end
		run_aborts_once(self)
		run_finallys_once(self, true)
	end

	local new_mt = {}
	for k, v in pairs(mt) do new_mt[k] = v end
	new_mt.__index = idx
	new_mt.__ann_decorated = true

	setmetatable(ticket, new_mt)
	return ticket
end

----------------------------------------------------------------------
-- Abort/cancel plumbing (for composites)
----------------------------------------------------------------------

local function post_abort_then_cancel(t, ctx)
	local pa = t._post_commit_abort
	if pa then
		pa(t, ctx)
	end
	t:cancel(ctx)
end

----------------------------------------------------------------------
-- Select: a general composite for choice/all/choose_k/and_then
----------------------------------------------------------------------

---@class SelectPlan
---@field picks integer[]
---@field props any[]     -- tuple aligned with picks: props[j] corresponds to picks[j]

---@class SelectPolicy
---@field nslots integer|nil
---@field build_plan fun(owner:any, ctx:table): integer[]|nil
---@field build_payload fun(owner:any, picks:integer[]): table
---@field cancel_losers boolean|nil
---@field on_child_cancelled string|nil   -- 'dead'|'cancel_all'
---@field on_pick_cancelled string|nil    -- 'retry'|'cancel_all'
---@field on_child fun(owner:any, ctx:table, i:integer, tag:string, prop:any, payload:table|nil, pulse:any)|nil

---@class SelectTicket
---@field _pulse Pulse
---@field kids table[]              -- may contain nil for uninstantiated slots
---@field watch Watch[]
---@field dead boolean[]
---@field props any[]               -- per-slot last preview proposal (nil if not preview-ready)
---@field vals table[]              -- per-slot last payload pack (preview or committed)
---@field phase string
---@field policy SelectPolicy
---@field prepared_plan SelectPlan|nil
---@field prepared_payload table|nil
---@field prepared_epoch integer|nil
---@field nslots integer
local SelectTicket = {}
SelectTicket.__index = SelectTicket

function SelectTicket:pulse() return self._pulse end

function SelectTicket:_clear_watches()
	for i = 1, self.nslots do
		watch_clear(self.watch[i])
	end
end

function SelectTicket:_withdraw_prepared()
	self.prepared_plan    = nil
	self.prepared_payload = nil
	self.prepared_epoch   = nil
end

function SelectTicket:_invalidate_slot(ctx, i)
	local kid = self.kids[i]
	if kid then kid:cancel(ctx) end

	self.kids[i]  = nil
	self.dead[i]  = nil
	self.props[i] = nil
	self.vals[i]  = nil
	watch_clear(self.watch[i])

	self:_withdraw_prepared()
end

function SelectTicket:_set_slot(ctx, i, opv)
	local t = opv:_instantiate(ctx)

	self.kids[i]  = t
	self.dead[i]  = nil
	self.props[i] = nil
	self.vals[i]  = nil
	watch_clear(self.watch[i])

	self:_withdraw_prepared()
	return t
end

local function call_on_child(owner, ctx, i, tag, prop, payload, pulse)
	local pol = owner.policy
	local f = pol and pol.on_child or nil
	if f then
		f(owner, ctx, i, tag, prop, payload, pulse)
	end
end

function SelectTicket:_watches_quiet()
	for i = 1, self.nslots do
		local w = self.watch[i]
		local p = w.watched
		local seen = w._seen_epoch
		if p and seen ~= nil and p._epoch ~= seen then
			return false
		end
	end
	return true
end

function SelectTicket:preview(ctx)
	if self.phase == PH_CANCELLED or self.phase == PH_ABORTED then
		return TAG_CANCELLED, nil, nil, nil
	end

	if self.phase == PH_DONE then
		return TAG_PREVIEW, self.prepared_plan, self.prepared_payload, self._pulse
	end

	-- Cache rule: a prepared plan remains valid until the owner pulse advances.
	local epoch = self._pulse._epoch

	if self.prepared_plan and self.prepared_epoch == epoch and self:_watches_quiet() then
		return TAG_PREVIEW, self.prepared_plan, self.prepared_payload, self._pulse
	end

	self:_withdraw_prepared()

	local any_pending   = false
	local any_remaining = false

	for i = 1, self.nslots do
		if not self.dead[i] then
			local kid = self.kids[i]

			if not kid then
				any_pending   = true
				any_remaining = true
				self.props[i] = nil
				self.vals[i]  = nil
				watch_clear(self.watch[i])

			else
				local tag, prop, payload, wpulse = kid:preview(ctx)
				call_on_child(self, ctx, i, tag, prop, payload, wpulse)

				-- Hook may have driven the composite to aborted.
				if self.phase == PH_ABORTED or self.phase == PH_CANCELLED then
					return TAG_CANCELLED, nil, nil, nil
				end

				if tag == TAG_PENDING then
					any_pending   = true
					any_remaining = true
					self.props[i] = nil
					self.vals[i]  = nil
					watch_set(self.watch[i], wpulse)

				elseif tag == TAG_PREVIEW then
					any_remaining = true
					self.props[i] = prop
					self.vals[i]  = payload
					watch_set(self.watch[i], wpulse or kid:pulse())

				else -- TAG_CANCELLED
					local mode    = self.policy.on_child_cancelled or 'dead'
					self.dead[i]  = true
					self.props[i] = nil
					self.vals[i]  = nil
					watch_clear(self.watch[i])
					kid:cancel(ctx)

					if mode == 'cancel_all' then
						self.phase = PH_ABORTED
						return TAG_CANCELLED, nil, nil, nil
					end
				end
			end
		end
	end

	local picks = self.policy.build_plan(self, ctx)
	if not picks then
		if any_pending or any_remaining then
			return TAG_PENDING, nil, nil, self._pulse
		end
		self.phase = PH_ABORTED
		return TAG_CANCELLED, nil, nil, nil
	end

	-- Proposal: tuple of child proposals aligned with picks.
	local props_tuple = {}
	for j = 1, #picks do
		local i = picks[j]
		props_tuple[j] = self.props[i]
	end

	local plan = { picks = picks, props = props_tuple }
	local payload = self.policy.build_payload(self, picks)

	self.prepared_plan    = plan
	self.prepared_payload = payload
	self.prepared_epoch   = epoch

	return TAG_PREVIEW, plan, payload, self._pulse
end

function SelectTicket:commit(ctx, expected_plan)
	if self.phase == PH_CANCELLED then return TAG_CANCELLED, nil, nil end

	if self.phase == PH_DONE then
		if expected_plan ~= self.prepared_plan then
			return TAG_PENDING, nil, self._pulse
		end
		return TAG_DONE, self.prepared_payload, nil
	end

	local plan = self.prepared_plan
	if (not plan) or expected_plan ~= plan then
		return TAG_PENDING, nil, self._pulse
	end

	local picks = plan.picks
	local props = plan.props

	for j = 1, #picks do
		local i = picks[j]

		if self.dead[i] then
			self:_withdraw_prepared()
			return TAG_PENDING, nil, self._pulse
		end

		local kid = self.kids[i]
		if not kid then
			self:_withdraw_prepared()
			return TAG_PENDING, nil, self._pulse
		end

		local tag, payload, wpulse = kid:commit(ctx, props[j])

		if tag == TAG_PENDING then
			watch_set(self.watch[i], wpulse)
			return TAG_PENDING, nil, self._pulse

		elseif tag == TAG_DONE then
			self.vals[i] = payload

		else -- TAG_CANCELLED
			local mode    = self.policy.on_pick_cancelled or 'retry'
			self.dead[i]  = true
			self.props[i] = nil
			self.vals[i]  = nil
			watch_clear(self.watch[i])
			kid:cancel(ctx)
			self:_withdraw_prepared()

			if mode == 'cancel_all' then
				self.phase = PH_ABORTED
				return TAG_CANCELLED, nil, nil
			end
			return TAG_PENDING, nil, self._pulse
		end
	end

	-- Rebuild payload from committed results (not merely preview payloads).
	self.prepared_payload = self.policy.build_payload(self, picks)

	if self.policy.cancel_losers ~= false then
		local picked = {}
		for j = 1, #picks do picked[picks[j]] = true end

		for i = 1, self.nslots do
			if (not picked[i]) and (not self.dead[i]) then
				local kid = self.kids[i]
				if kid then
					post_abort_then_cancel(kid, ctx)
				end
				self.dead[i]  = true
				self.props[i] = nil
				self.vals[i]  = nil
				watch_clear(self.watch[i])
			end
		end
	end

	self.phase = PH_DONE
	self.prepared_epoch = nil
	self:_clear_watches()
	return TAG_DONE, self.prepared_payload, nil
end

function SelectTicket:cancel(ctx)
	-- Idempotent, and distinguishes “aborted” from “cancelled”.
	if self.phase == PH_CANCELLED then return end
	if self.phase == PH_DONE then return end

	self.phase = PH_CANCELLED
	self:_withdraw_prepared()
	self:_clear_watches()

	for i = 1, self.nslots do
		local kid = self.kids[i]
		if kid then kid:cancel(ctx) end
	end
end

function SelectTicket:_post_commit_abort(ctx)
	for i = 1, self.nslots do
		local k = self.kids[i]
		if k then
			local pa = k._post_commit_abort
			if pa then pa(k, ctx) end
		end
	end
end

---@param ctx table
---@param ops Op[]
---@param policy SelectPolicy
---@return table
local function instantiate_select(ctx, ops, policy)
	local nslots = policy.nslots or #ops
	local kids = {}

	for i = 1, nslots do
		local opv = ops[i]
		if opv then
			kids[i] = opv:_instantiate(ctx)
		else
			kids[i] = nil
		end
	end

	local owner = {
		_pulse = new_pulse(),
		kids   = kids,
		watch  = {},
		dead   = {},
		props  = {},
		vals   = {},
		phase  = PH_OPEN,
		policy = policy,
		nslots = nslots,
	}

	local waker = ctx.scheduler
	for i = 1, nslots do
		owner.watch[i] = watch_new(owner, waker)
	end

	return setmetatable(owner, SelectTicket)
end

----------------------------------------------------------------------
-- Op representation and instantiation
----------------------------------------------------------------------

Op = {}
Op.__index = Op

function Op:_instantiate(ctx)
	local k = self.kind

	if k == 'prim' then
		return self.start_fn(ctx)

	elseif k == 'guard' then
		return self.thunk():_instantiate(ctx)

	elseif k == 'decor' then
		local inner_ticket = self.inner:_instantiate(ctx)
		return decorate_ticket(inner_ticket, self.ann)

	elseif k == 'select' then
		return instantiate_select(ctx, self.ops, self.policy)
	end

	return nil
end

----------------------------------------------------------------------
-- Helpers: input validation and decoration merging
----------------------------------------------------------------------

local function assert_op(x, depth)
	if type(x) ~= 'table' or getmetatable(x) ~= Op then
		error('expected Op', depth or 2)
	end
	return x
end

local function normalise_ops(varargs, depth)
	local ops = { unpack(varargs) }
	for i = 1, #ops do assert_op(ops[i], (depth or 2) + 1) end
	return ops
end

local function decorate_op(inner, add_ann)
	if inner.kind == 'decor' then
		return setmetatable({
			kind  = 'decor',
			inner = inner.inner,
			ann   = ann_merge(inner.ann, add_ann),
		}, Op)
	end
	return setmetatable({ kind = 'decor', inner = inner, ann = add_ann }, Op)
end

----------------------------------------------------------------------
-- Public constructors
----------------------------------------------------------------------

---@param start_fn fun(ctx: table): table
---@return Op
local function new_primitive(start_fn)
	if type(start_fn) ~= 'function' then error('new_primitive expects a function', 2) end
	return setmetatable({ kind = 'prim', start_fn = start_fn }, Op)
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
			_proposal = 1,
			_payload  = payload,
		}, AlwaysTicket)
	end)
end

---@return Op
local function never()
	return new_primitive(function (_ctx)
		return setmetatable({ _pulse = new_pulse() }, NeverTicket)
	end)
end

-- Policies -----------------------------------------------------------

-- choice: first preview-ready arm wins; payload is the winner's payload pack.
local function plan_choice(owner, _ctx)
	for i = 1, owner.nslots do
		if (not owner.dead[i]) and owner.props[i] ~= nil then
			return { i }
		end
	end
	return nil
end

local function payload_choice(owner, picks)
	return owner.vals[picks[1]]
end

-- all: requires all preview-ready; returns ONE value: a table of payload packs.
local function plan_all(owner, _ctx)
	for i = 1, owner.nslots do
		if owner.dead[i] or owner.props[i] == nil then
			return nil
		end
	end
	local picks = {}
	for i = 1, owner.nslots do picks[i] = i end
	return picks
end

local function payload_table_of_packs(owner, picks)
	local t = {}
	for j = 1, #picks do
		t[j] = owner.vals[picks[j]]
	end
	return { n = 1, t }
end

local function make_plan_choose_k(k)
	return function (owner, _ctx)
		local picks = {}
		for i = 1, owner.nslots do
			if (not owner.dead[i]) and owner.props[i] ~= nil then
				picks[#picks + 1] = i
				if #picks == k then return picks end
			end
		end
		return nil
	end
end

-- and_then: two slots, RHS depends on LHS preview payload.
local function make_policy_and_then(k)
	if type(k) ~= 'function' then error('and_then expects a function', 3) end

	return {
		nslots             = 2,
		cancel_losers      = false,
		on_child_cancelled = 'cancel_all',
		on_pick_cancelled  = 'cancel_all',

		build_plan = function (owner, _ctx)
			if owner.dead[1] or owner.dead[2] then return nil end
			if owner.props[1] ~= nil and owner.props[2] ~= nil then
				return { 1, 2 }
			end
			return nil
		end,

		build_payload = function (owner, _picks)
			return owner.vals[2] -- RHS payload pack
		end,

		on_child = function (owner, ctx, i, tag, prop, payload, _pulse)
			if i ~= 1 then return end

			local function invalidate_rhs()
				owner:_invalidate_slot(ctx, 2)
			end

			if tag == TAG_PENDING then
				if owner._and_then_left_p ~= nil then
					owner._and_then_left_p = nil
					invalidate_rhs()
				end
				return
			end

			if tag ~= TAG_PREVIEW then
				return
			end

			if owner._and_then_left_p ~= prop then
				owner._and_then_left_p = prop
				invalidate_rhs()

				local opv = k(unpack(payload, 1, payload.n))
				if type(opv) ~= 'table' or getmetatable(opv) ~= Op then
					error('and_then: function must return an Op', 0)
				end
				owner:_set_slot(ctx, 2, opv)
			end
		end,
	}
end


---@param ... Op
---@return Op
local function choice(...)
	local ops = normalise_ops({ ... }, 2)
	if #ops == 0 then error('choice expects at least one op', 2) end
	if #ops == 1 then return ops[1] end

	return setmetatable({
		kind   = 'select',
		ops    = ops,
		policy = {
			build_plan         = plan_choice,
			build_payload      = payload_choice,
			cancel_losers      = true,
			on_child_cancelled = 'dead',
			on_pick_cancelled  = 'retry',
		},
	}, Op)
end

---@param ... Op
---@return Op
local function all(...)
	local ops = normalise_ops({ ... }, 2)
	if #ops == 0 then error('all expects at least one op', 2) end
	if #ops == 1 then return ops[1] end

	return setmetatable({
		kind   = 'select',
		ops    = ops,
		policy = {
			build_plan         = plan_all,
			build_payload      = payload_table_of_packs,
			cancel_losers      = false,
			on_child_cancelled = 'cancel_all',
			on_pick_cancelled  = 'cancel_all',
		},
	}, Op)
end

---@param k integer
---@param ... Op
---@return Op
local function choose_k(k, ...)
	if type(k) ~= 'number' or k % 1 ~= 0 or k < 1 then
		error('choose_k expects a positive integer k', 2)
	end
	local ops = normalise_ops({ ... }, 2)
	if #ops < k then error('choose_k expects at least k ops', 2) end

	return setmetatable({
		kind   = 'select',
		ops    = ops,
		policy = {
			build_plan         = make_plan_choose_k(k),
			build_payload      = payload_table_of_packs,
			cancel_losers      = true,
			on_child_cancelled = 'dead',
			on_pick_cancelled  = 'retry',
		},
	}, Op)
end

---@param ... Op
---@return Op
local function choose2(...)
	return choose_k(2, ...)
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
		return use(res):finally(function (aborted)
			pcall(release, res, aborted)
		end)
	end)
end

function Op:wrap(f)
	if type(f) ~= 'function' then error('wrap expects a function', 2) end
	return decorate_op(self, { wraps = { f } })
end

function Op:on_abort(f)
	if type(f) ~= 'function' then error('on_abort expects a function', 2) end
	return decorate_op(self, { aborts = { f } })
end

function Op:finally(cleanup)
	if type(cleanup) ~= 'function' then error('finally expects a function', 2) end
	return decorate_op(self, { finallys = { cleanup } })
end

function Op:and_then(k)
	-- Expressed as a 2-slot select: slot1=lhs, slot2 instantiated from lhs preview payload.
	return setmetatable({
		kind   = 'select',
		ops    = { self }, -- only slot 1 is pre-instantiated; slot 2 starts nil
		policy = make_policy_and_then(k),
	}, Op)
end

----------------------------------------------------------------------
-- perform(op): attempt loop
----------------------------------------------------------------------

-- Per-fibre ctx cache (weak keys)
local ctx_by_fiber = setmetatable({}, { __mode = 'k' })

local function perform(opv)
	local scheduler = runtime.current_scheduler
	local fib = assert(runtime.current_fiber())

	local ctx = ctx_by_fiber[fib] or {
			gate_state = GATE_OPEN,
			scheduler  = scheduler,
			_wait_node = {
				_linked = false,
				_task   = fib,
				_waker  = scheduler,
			},
		}
	ctx_by_fiber[fib] = ctx

	local root = opv:_instantiate(ctx)

	local root_preview = root.preview
	local root_commit  = root.commit
	local root_cancel  = root.cancel

	while true do
		ctx.gate_state = GATE_OPEN

		local proposal
		while true do
			local tag, p, _payload, pulse = root_preview(root, ctx)
			if tag == TAG_PREVIEW then
				proposal = p
				break
			elseif tag == TAG_PENDING then
				block_on_pulse(ctx, pulse)
			else
				ctx.gate_state = GATE_ABORTED
				root_cancel(root, ctx)
				error('perform: cancelled', 0)
			end
		end

		ctx.gate_state = GATE_COMMITTING

		local tag, payload, pulse = root_commit(root, ctx, proposal)

		if tag == TAG_DONE then
			if not payload or payload.n == 0 then return end
			return unpack(payload, 1, payload.n)
		elseif tag == TAG_PENDING then
			block_on_pulse(ctx, pulse)
		else
			ctx.gate_state = GATE_ABORTED
			root_cancel(root, ctx)
			error('perform: cancelled during commit', 0)
		end
	end
end

return {
	perform = perform,

	new_primitive = new_primitive,
	choice        = choice,
	all           = all,
	choose2       = choose2,
	choose_k      = choose_k,
	guard         = guard,
	always        = always,
	never         = never,
	bracket       = bracket,

	Op = Op,

	-- for primitive authors / tests
	Pulse     = Pulse,
	new_pulse = new_pulse,

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
	pack  = pack,
	EMPTY = EMPTY,
}

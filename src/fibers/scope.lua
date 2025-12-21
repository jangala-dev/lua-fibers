-- fibers/scope.lua
--
-- Stable core structured concurrency scopes that complement the Op layer.
--
-- This module provides supervision “scopes” for cooperative fibers. Scopes are
-- intended to be the unit of lifetime, cancellation and failure accounting,
-- with explicit boundaries for crossing between scopes.
--
-- Guarantees
--   * Structural lifetime: attached children are joined by the parent join,
--     including child finalisers, in attachment order.
--   * Admission gate: close() stops new spawn()/child() on the scope.
--     Joining also closes admission (but does not imply cancellation).
--   * Downward cancellation: cancel() closes admission and cascades to attached
--     children. Cancellation is a normal termination mode, distinct from failure.
--   * Fail-fast within a scope: the first non-cancellation fault marks the scope
--     failed, records a primary error, and cancels the scope to stop siblings.
--   * Join/finalisation is non-interruptible: join runs in a join worker and uses
--     op.perform_raw, so it is not interrupted by scope cancellation.
--   * Scope-aware ops:
--       - try(ev)     -> 'ok'|'failed'|'cancelled', ...
--       - perform(ev) -> returns results on ok; raises on failed/cancelled
--                       (using a cancellation sentinel for cancelled).
--   * Boundaries (status-first, report-second):
--       - join_op() -> status, report, primary|nil
--       - run(fn, ...) -> status, report, ...          (on not-ok: ... is primary)
--       - run_op(fn, ...) -> Op yielding status, report, ... (on not-ok: ... is primary)
--
-- Notes
--   * Returning variable arity across boundaries follows Lua conventions.
--     As with any multi-return, trailing nil results are not preserved.
--
-- Deliberate non-feature
--   * No implicit upward propagation of child failure into parent failure.
--     Child outcomes are reported (via reports), not escalated.
--
---@module 'fibers.scope'

local runtime   = require 'fibers.runtime'
local waitgroup = require 'fibers.waitgroup'
local oneshot   = require 'fibers.oneshot'
local op        = require 'fibers.op'
local safe      = require 'coxpcall'

local DEBUG = false

--- Enable/disable debug traceback capture.
---@param v boolean
local function set_debug(v) DEBUG = not not v end

local unpack = rawget(table, 'unpack') or _G.unpack
local pack   = rawget(table, 'pack') or function (...)
	return { n = select('#', ...), ... }
end

----------------------------------------------------------------------
-- Cancellation sentinel (robust, non-colliding)
----------------------------------------------------------------------

local CANCEL_MT = {}
CANCEL_MT.__name = 'fibers.cancelled'

---@class Cancelled
---@field reason any

---@param reason any
---@return Cancelled
local function cancelled(reason)
	return setmetatable({ reason = reason }, CANCEL_MT)
end

---@param err any
---@return boolean
local function is_cancelled(err)
	return type(err) == 'table' and getmetatable(err) == CANCEL_MT
end

---@param err any
---@return any|nil
local function cancel_reason(err)
	return is_cancelled(err) and err.reason or nil
end

---@param err any
local function raise_any(err)
	error(err, 0)
end

----------------------------------------------------------------------
-- Error normalisation policy (xpcall handlers)
----------------------------------------------------------------------

---@param kind '"body"'|'"join"'|'"finaliser"'
---@return fun(e:any): any
local function make_xpcall_handler(kind)
	return function (e)
		if is_cancelled(e) then
			if kind == 'join' then
				local msg = 'join raised cancellation: ' .. tostring(cancel_reason(e))
				if DEBUG then return debug.traceback(msg, 2) end
				return msg
			end
			-- body/finaliser: propagate cancellation sentinel for control flow
			return e
		end

		local msg = tostring(e)
		if DEBUG then return debug.traceback(msg, 2) end
		return msg
	end
end

local tb_handler        = make_xpcall_handler('body')
local join_tb_handler   = make_xpcall_handler('join')
local finaliser_handler = make_xpcall_handler('finaliser')

----------------------------------------------------------------------
-- Types / state
----------------------------------------------------------------------

---@class ScopeChildOutcome
---@field id integer
---@field status "ok"|"failed"|"cancelled"
---@field primary any
---@field report ScopeReport

---@class ScopeReport
---@field id integer
---@field extra_errors any[]
---@field children ScopeChildOutcome[]

---@class ScopeJoinOutcome
---@field st "ok"|"failed"|"cancelled"
---@field primary any
---@field report ScopeReport

---@class ScopeTerminal
---@field failed any|nil     -- primary failure (string/number) if failed
---@field cancelled any|nil  -- cancellation reason if cancelled

---@class Scope
---@field _id integer
---@field _parent Scope|nil
---@field _children table<Scope, boolean>
---@field _order Scope[]
---@field _wg Waitgroup
---@field _closed boolean
---@field _close_reason any|nil
---@field _close_os Oneshot
---@field _terminal ScopeTerminal|nil
---@field _cancel_os Oneshot
---@field _extra_errors any[]
---@field _fault_os Oneshot
---@field _finalisers function[]
---@field _join_started boolean
---@field _join_outcome ScopeJoinOutcome|nil
---@field _join_os Oneshot
local Scope = {}
Scope.__index = Scope

-- Weak-key map: Fiber -> Scope for attribution of uncaught runtime fiber errors.
local fiber_scopes = setmetatable({}, { __mode = 'k' })

-- Process-wide root scope.
local root_scope

-- Monotonic scope id sequence (local to the process).
local next_id = 0

local function current_fiber()
	return runtime.current_fiber()
end

----------------------------------------------------------------------
-- Unscoped error handling
----------------------------------------------------------------------

local function default_unscoped_error_handler(_, err)
	io.stderr:write('Unscoped fiber error: ' .. tostring(err) .. '\n')
end

local unscoped_error_handler = default_unscoped_error_handler

---@param handler fun(fib:any, err:any)
local function set_unscoped_error_handler(handler)
	assert(type(handler) == 'function', 'unscoped error handler must be a function')
	unscoped_error_handler = handler
end

----------------------------------------------------------------------
-- Current scope install/restore (fiber-local only)
----------------------------------------------------------------------

---@param s Scope
---@return any fib_or_nil, Scope|nil prev
local function install_current_scope(s)
	local fib = current_fiber()
	if not fib then
		return nil, nil
	end
	local prev = fiber_scopes[fib]
	fiber_scopes[fib] = s
	return fib, prev
end

---@param fib any|nil
---@param prev Scope|nil
local function restore_current_scope(fib, prev)
	if fib then
		fiber_scopes[fib] = prev
	end
end

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------

---@param t any[]
---@return any[]
local function copy_array(t)
	local out = {}
	for i = 1, #t do out[i] = t[i] end
	return out
end

---@param self Scope
---@return Scope[]
local function snapshot_children_set(self)
	local snap = {}
	for ch in pairs(self._children) do snap[#snap + 1] = ch end
	return snap
end

--- Build a primitive op from an oneshot-like readiness predicate.
--- When ready, yields whatever get_values() returns (any arity).
---@param is_ready fun(): boolean
---@param os Oneshot
---@param get_values fun(): ...
---@param on_block? fun()
---@return Op
local function oneshot_value_op(is_ready, os, get_values, on_block)
	return op.new_primitive(
		nil,
		function ()
			if is_ready() then
				return true, get_values()
			end
			return false
		end,
		function (suspension, wrap_fn)
			local cancel = os:add_waiter(function ()
				if suspension:waiting() then
					suspension:complete(wrap_fn, get_values())
				end
			end)
			suspension:add_cleanup(cancel)
			if on_block then on_block() end
		end
	)
end

---@param self Scope
---@return "ok"|"failed"|"cancelled", any
local function terminal_status(self)
	local t = self._terminal
	if t and t.failed ~= nil then return 'failed', t.failed end
	if t and t.cancelled ~= nil then return 'cancelled', t.cancelled end
	return 'ok', nil
end

---@param self Scope
---@param child_outcomes? ScopeChildOutcome[]
---@return ScopeReport
local function make_report(self, child_outcomes)
	return {
		id           = self._id,
		extra_errors = copy_array(self._extra_errors),
		children     = child_outcomes or {},
	}
end

--- Return a rejection reason if the scope is not admitting new work; otherwise nil.
---@param self Scope
---@return string|nil
local function reject_reason(self)
	if self._join_outcome ~= nil or self._join_started then return 'scope is joining' end

	local t = self._terminal
	if t and t.failed ~= nil then return 'scope has failed' end
	if t and t.cancelled ~= nil then return 'scope is cancelled' end

	if self._closed then return 'scope is closed' end
	return nil
end

----------------------------------------------------------------------
-- Observational status (non-blocking snapshot)
----------------------------------------------------------------------

---@return string st
---@return any v
function Scope:status()
	local out = self._join_outcome
	if out then return out.st, out.primary end

	local t = self._terminal
	if t and t.failed ~= nil then return 'failed', t.failed end
	if t and t.cancelled ~= nil then return 'cancelled', t.cancelled end
	return 'running', nil
end

---@return string st
---@return any reason
function Scope:admission()
	if self._closed then return 'closed', self._close_reason end
	return 'open', nil
end

----------------------------------------------------------------------
-- Construction / root / current
----------------------------------------------------------------------

---@param parent Scope|nil
---@return Scope
local function new_scope(parent)
	next_id = next_id + 1

	local s = setmetatable({
		_id       = next_id,
		_parent   = parent,
		_children = {},
		_order    = {},
		_wg       = waitgroup.new(),

		_closed       = false,
		_close_reason = nil,
		_close_os     = oneshot.new(),

		_terminal  = nil,
		_cancel_os = oneshot.new(),

		_extra_errors = {},
		_fault_os     = oneshot.new(),

		_finalisers   = {},
		_join_started = false,
		_join_outcome = nil,
		_join_os      = oneshot.new(),
	}, Scope)

	if parent then
		parent._children[s] = true
		parent._order[#parent._order + 1] = s

		-- Downward cancellation propagates immediately to new children.
		local pt = parent._terminal
		if pt and pt.cancelled ~= nil then
			s:cancel(pt.cancelled)
		end
	end

	return s
end

---@return Scope
local function root()
	if root_scope then return root_scope end

	root_scope = new_scope(nil)

	-- Error pump: route uncaught runtime errors to the owning scope when possible.
	runtime.spawn_raw(function ()
		while true do
			local fib, err = runtime.wait_fiber_error()
			if not is_cancelled(err) then
				local s = fiber_scopes[fib]
				if s then
					s:_record_fault(err)
				else
					unscoped_error_handler(fib, err)
				end
			end
		end
	end)

	return root_scope
end

--- Return the current scope.
--- Inside a fiber: the fiber's scope, defaulting to root.
--- Outside fibers: always the root scope.
---@return Scope
local function current()
	local fib = current_fiber()
	if fib then return fiber_scopes[fib] or root() end
	return root()
end

----------------------------------------------------------------------
-- Child management (attachment)
----------------------------------------------------------------------

---@param self Scope
---@param child Scope
function Scope:_remove_child(child)
	if child._parent ~= self then return end
	self._children[child] = nil

	local ord = self._order
	for i = #ord, 1, -1 do
		if ord[i] == child then
			table.remove(ord, i)
			break
		end
	end

	child._parent = nil
end

function Scope:_detach_from_parent()
	local p = self._parent
	if p then p:_remove_child(self) end
end

---@return Scope|nil child, any|nil err
function Scope:child()
	local why = reject_reason(self)
	if why then return nil, why end
	return new_scope(self), nil
end

----------------------------------------------------------------------
-- Admission gate (close)
----------------------------------------------------------------------

---@param reason any|nil
function Scope:close(reason)
	if self._join_outcome ~= nil then return end

	if not self._closed then
		self._closed = true
		self._close_reason = (reason ~= nil) and reason or self._close_reason
		self._close_os:signal()
	elseif self._close_reason == nil and reason ~= nil then
		self._close_reason = reason
	end
end

---@return Op
function Scope:close_op()
	return oneshot_value_op(
		function () return self._closed end,
		self._close_os,
		function () return 'closed', self._close_reason end
	)
end

----------------------------------------------------------------------
-- Cancellation / faults
----------------------------------------------------------------------

---@param reason any|nil
function Scope:cancel(reason)
	if self._join_outcome ~= nil then return end

	-- Cancellation implies admission is closed.
	self:close(reason)

	local t = self._terminal
	if not t then
		t = { failed = nil, cancelled = nil }
		self._terminal = t
	end

	if t.cancelled == nil then
		t.cancelled = (reason ~= nil) and reason or 'scope cancelled'
		self._cancel_os:signal()
	end

	-- Cancel attached children (snapshot avoids mutation hazards).
	local snap = snapshot_children_set(self)
	for i = 1, #snap do snap[i]:cancel(t.cancelled) end
end

---@param err any
function Scope:_record_fault(err)
	if is_cancelled(err) then
		self:cancel(cancel_reason(err))
		return
	end

	-- Normalise error to a reportable primitive (string/number).
	local e = err
	if type(e) ~= 'string' and type(e) ~= 'number' then
		e = tostring(e)
	end

	local t = self._terminal
	if t and t.failed ~= nil then
		-- Subsequent faults are recorded as extra errors.
		self._extra_errors[#self._extra_errors + 1] = e
		return
	end

	if not t then
		t = { failed = nil, cancelled = nil }
		self._terminal = t
	end

	-- First fault becomes primary; fail-fast by cancelling.
	t.failed = e
	self._fault_os:signal()

	-- Ensure cancellation is requested (without overriding an existing reason).
	if t.cancelled == nil then
		t.cancelled = e
		self._cancel_os:signal()
	end

	-- Downward cancellation stops siblings/children.
	self:cancel(t.cancelled)
end

---@return Op
function Scope:cancel_op()
	return oneshot_value_op(
		function ()
			local t = self._terminal
			return t ~= nil and t.cancelled ~= nil
		end,
		self._cancel_os,
		function ()
			local t = self._terminal
			return 'cancelled', t and t.cancelled or nil
		end
	)
end

---@return Op
function Scope:fault_op()
	return oneshot_value_op(
		function ()
			local t = self._terminal
			return t ~= nil and t.failed ~= nil
		end,
		self._fault_os,
		function ()
			local t = self._terminal
			return 'failed', t and t.failed or nil
		end
	)
end

---@return Op
function Scope:not_ok_op()
	return op.choice(self:fault_op(), self:cancel_op()):wrap(function ()
		local t = self._terminal
		if t and t.failed ~= nil then return 'failed', t.failed end
		return 'cancelled', t and t.cancelled or nil
	end)
end

----------------------------------------------------------------------
-- Finalisers
----------------------------------------------------------------------

---@param f fun(aborted:boolean, status:string, primary:any|nil)
function Scope:finally(f)
	assert(type(f) == 'function', 'scope:finally expects a function')
	self._finalisers[#self._finalisers + 1] = f
end

----------------------------------------------------------------------
-- Spawning (attached obligations)
----------------------------------------------------------------------

---@param fn fun(s:Scope, ...): any
---@param ... any
---@return boolean ok, any|nil err
function Scope:spawn(fn, ...)
	local why = reject_reason(self)
	if why then return false, why end

	local args = pack(...)
	self._wg:add(1)

	runtime.spawn_raw(function ()
		local fib, prev = install_current_scope(self)

		local ok, err = safe.xpcall(function ()
			return fn(self, unpack(args, 1, args.n))
		end, tb_handler)

		restore_current_scope(fib, prev)

		if not ok then self:_record_fault(err) end
		self._wg:done()
	end)

	return true, nil
end

----------------------------------------------------------------------
-- Join (non-interruptible finalisation)
----------------------------------------------------------------------

---@param self Scope
---@return ScopeChildOutcome[]
function Scope:_finalise_join_body()
	self:close('joining')

	local children = copy_array(self._order)
	local child_outcomes = {}

	op.perform_raw(self._wg:wait_op())

	for i = 1, #children do
		local ch = children[i]
		if ch and ch._parent == self then
			local st, rep, primary = op.perform_raw(ch:join_op())
			child_outcomes[#child_outcomes + 1] = {
				id      = ch._id,
				status  = st,
				primary = primary,
				report  = rep,
			}
			self:_remove_child(ch)
		end
	end

	local st, primary = terminal_status(self)
	local aborted = (st ~= 'ok')

	local fs = self._finalisers
	for i = #fs, 1, -1 do
		local f = fs[i]
		fs[i] = nil

		local ok, err = safe.xpcall(function ()
			return f(aborted, st, (st == 'failed') and primary or nil)
		end, finaliser_handler)

		if not ok then
			if is_cancelled(err) then
				self:_record_fault('finaliser raised cancellation: ' .. tostring(cancel_reason(err)))
			else
				self:_record_fault(err)
			end
			st, primary = terminal_status(self)
			aborted = (st ~= 'ok')
		end
	end

	return child_outcomes
end

function Scope:_start_join_worker()
	if self._join_started then return end
	self._join_started = true

	runtime.spawn_raw(function ()
		local fib, prev = install_current_scope(self)

		local child_outcomes
		local ok, err = safe.xpcall(function ()
			child_outcomes = self:_finalise_join_body()
		end, join_tb_handler)

		restore_current_scope(fib, prev)

		if not ok then self:_record_fault(err) end

		local st, primary = terminal_status(self)
		local rep = make_report(self, child_outcomes or {})

		self._join_outcome = { st = st, primary = primary, report = rep }
		self._join_os:signal()

		self:_detach_from_parent()
	end)
end

---@return Op
function Scope:join_op()
	return oneshot_value_op(
		function () return self._join_outcome ~= nil end,
		self._join_os,
		function ()
			local out = self._join_outcome
			if out then return out.st, out.report, out.primary end
			-- Defensive fallback.
			local st, primary = terminal_status(self)
			return st, make_report(self, {}), primary
		end,
		function () self:_start_join_worker() end
	)
end

----------------------------------------------------------------------
-- Scope-aware op performance (status-first)
----------------------------------------------------------------------

---@param ev any
local function assert_op_value(ev)
	if type(ev) ~= 'table' or getmetatable(ev) ~= op.Op then
		error(('scope: expected op, got %s (%s)'):format(type(ev), tostring(ev)), 3)
	end
end

---@param ev Op
---@return Op
function Scope:try_op(ev)
	assert_op_value(ev)

	return op.guard(function ()
		local t = self._terminal
		if t and t.failed ~= nil then return op.always('failed', t.failed) end
		if t and t.cancelled ~= nil then return op.always('cancelled', t.cancelled) end

		local body = ev:wrap(function (...)
			local t2 = self._terminal
			if t2 and t2.failed ~= nil then return 'failed', t2.failed end
			if t2 and t2.cancelled ~= nil then return 'cancelled', t2.cancelled end
			return 'ok', ...
		end)

		return op.choice(body, self:not_ok_op())
	end)
end

---@param ev Op
---@return "ok"|"failed"|"cancelled", ...
function Scope:try(ev)
	assert(runtime.current_fiber(), 'scope:try must be called from inside a fiber')
	return op.perform_raw(self:try_op(ev))
end

---@param ev Op
---@return any ...
function Scope:perform(ev)
	local r = pack(self:try(ev))
	local st = r[1]
	if st == 'ok' then return unpack(r, 2, r.n) end
	if st == 'cancelled' then raise_any(cancelled(r[2])) end
	raise_any(r[2] or 'scope failed')
end

----------------------------------------------------------------------
-- Boundaries
----------------------------------------------------------------------

---@param body_fn fun(s:Scope, ...): ...
---@param ... any
---@return Op
local function run_op(body_fn, ...)
	assert(type(body_fn) == 'function', 'scope.run_op expects a function')

	local args = pack(...)

	return op.guard(function ()
		local parent = current()

		local child     = nil
		local child_err = nil
		local results   = nil

		local function start_once()
			if child ~= nil or child_err ~= nil then return end

			child, child_err = parent:child()
			if not child then return end

			local ok_spawn, spawn_err = child:spawn(function (s)
				local ok, err = safe.xpcall(function ()
					results = pack(body_fn(s, unpack(args, 1, args.n)))
				end, tb_handler)

				if not ok then s:_record_fault(err) end

				s:close('body complete')
				s:_start_join_worker()
			end)

			if not ok_spawn then
				child:_record_fault(spawn_err)
				child:close('body spawn failed')
				child:_start_join_worker()
			end
		end

		local function complete_from_join(suspension, wrap_fn)
			local out = child and child._join_outcome or nil
			if not out then
				local st, primary = terminal_status(child)
				suspension:complete(wrap_fn, st, make_report(child, {}), primary)
				return
			end

			if out.st == 'ok' then
				local r = results or pack()
				suspension:complete(wrap_fn, 'ok', out.report, unpack(r, 1, r.n))
			else
				suspension:complete(wrap_fn, out.st, out.report, out.primary)
			end
		end

		local function try_fn()
			local why = reject_reason(parent)
			if why then
				return true, 'cancelled', make_report(parent, {}), why
			end
			return false
		end

		local function block_fn(suspension, wrap_fn)
			start_once()

			if not child then
				suspension:complete(wrap_fn, 'cancelled', make_report(parent, {}), child_err)
				return
			end

			local cancel_join = child._join_os:add_waiter(function ()
				if suspension:waiting() then complete_from_join(suspension, wrap_fn) end
			end)
			suspension:add_cleanup(cancel_join)

			if child._join_outcome and suspension:waiting() then
				complete_from_join(suspension, wrap_fn)
			end
		end

		local ev = op.new_primitive(nil, try_fn, block_fn)

		return ev:on_abort(function ()
			if not child then return end
			child:cancel('aborted')
			child:_start_join_worker()
			safe.pcall(function () op.perform_raw(child:join_op()) end)
		end)
	end)
end

---@param body_fn fun(s:Scope, ...): ...
---@param ... any
---@return '"ok"'|'"failed"'|'"cancelled"', ScopeReport, any ...
local function run(body_fn, ...)
	assert(type(body_fn) == 'function', 'scope.run expects a function body')
	assert(runtime.current_fiber(), 'scope.run must be called from inside a fiber')
	return op.perform_raw(run_op(body_fn, ...))
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

return {
	root    = root,
	current = current,
	Scope   = Scope,

	run    = run,
	run_op = run_op,

	cancelled     = cancelled,
	is_cancelled  = is_cancelled,
	cancel_reason = cancel_reason,

	set_debug = set_debug,

	set_unscoped_error_handler = set_unscoped_error_handler,
}

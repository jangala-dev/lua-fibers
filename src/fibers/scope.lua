-- fibers/scope.lua
--
-- Stable core structured concurrency scopes that complement the Op layer.
--
-- Guarantees:
--   * structural lifetime: attached children are joined
--   * admission gate: close() stops new spawn/child; join starts by closing admission
--   * downward cancellation: cancel() cascades to attached children
--   * fail-fast within a scope: first fault marks failed and cancels the scope
--   * join/finalisation is non-interruptible: runs in a join worker using op.perform_raw
--   * scope-aware ops:
--       - try(ev) -> 'ok'|'failed'|'cancelled', ...
--       - perform(ev) raises on failed/cancelled (using a cancellation sentinel)
--   * boundaries:
--       - join_op() -> status, primary, report
--       - run(fn, ...) -> status, value_or_primary, report   (value is packed results table on ok)
--       - with_op(build_op) -> Op yielding status, value_or_primary, report
--
-- Deliberate non-feature:
--   * no implicit upward propagation of child failure into parent failure.
--     Child outcomes are reported, not escalated.
--
---@module 'fibers.scope'

local runtime   = require 'fibers.runtime'
local waitgroup = require 'fibers.waitgroup'
local oneshot   = require 'fibers.oneshot'
local op        = require 'fibers.op'
local safe      = require 'coxpcall'

-- Debug flag: when true, capture full tracebacks via xpcall handlers.
-- When false, use yield-safe pcall and keep errors compact.
local DEBUG = false

local function set_debug(v)
	DEBUG = not not v
end

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

local function raise_any(err)
	-- Raise the value verbatim so cancellation sentinels (tables/userdata)
	-- remain distinguishable. tb_handler() will stringify non-cancellation
	-- errors for reporting.
	error(err, 0)
end

---@param fn fun(): any
---@param handler fun(e:any): any
---@return boolean ok, any err
local function protected_call(fn, handler)
	if DEBUG then
		-- Full diagnostics path
		return safe.xpcall(fn, handler)
	else
		-- Compact path (yield-safe)
		return safe.pcall(fn)
	end
end

-- Preserve cancellation sentinel; otherwise return traceback string.
local function tb_handler(e)
	if is_cancelled(e) then return e end
	return debug.traceback(tostring(e), 2)
end

-- Join must not be interruptible by cancellation: render cancellation as a traceback.
local function join_tb_handler(e)
	if is_cancelled(e) then
		return debug.traceback('join raised cancellation: ' .. tostring(cancel_reason(e)), 2)
	end
	return debug.traceback(tostring(e), 2)
end

-- Finalisers preserve cancellation sentinel so we can treat it explicitly.
local function finaliser_tb_handler(e)
	if is_cancelled(e) then return e end
	return debug.traceback(tostring(e), 2)
end

----------------------------------------------------------------------
-- Types / state
----------------------------------------------------------------------

---@class ScopeChildOutcome
---@field id integer
---@field status '"ok"'|'"failed"'|'"cancelled"'
---@field primary any
---@field report ScopeReport

---@class ScopeReport
---@field id integer
---@field extra_errors any[]
---@field children ScopeChildOutcome[]

---@class ScopeJoinOutcome
---@field st '"ok"'|'"failed"'|'"cancelled"'
---@field primary any
---@field report ScopeReport

---@class Scope
---@field _id integer
---@field _parent Scope|nil
---@field _children table<Scope, boolean>
---@field _order Scope[]
---@field _wg Waitgroup
---@field _closed boolean
---@field _close_reason any|nil
---@field _close_os Oneshot
---@field _cancelled boolean
---@field _cancel_reason any|nil
---@field _cancel_os Oneshot
---@field _primary_error any|nil
---@field _extra_errors any[]
---@field _fault_os Oneshot
---@field _finalisers function[]
---@field _join_started boolean
---@field _join_outcome ScopeJoinOutcome|nil
---@field _join_os Oneshot
local Scope = {}
Scope.__index = Scope

-- Weak-key map: Fiber -> Scope for attribution of uncaught runtime fibre errors.
local fiber_scopes = setmetatable({}, { __mode = 'k' })

local root_scope, global_scope
local next_id = 0

local function current_fiber()
	return runtime.current_fiber()
end

----------------------------------------------------------------------
-- Unscoped error handling
----------------------------------------------------------------------

local function default_unscoped_error_handler(_, err)
	io.stderr:write('Unscoped fibre error: ' .. tostring(err) .. '\n')
end

local unscoped_error_handler = default_unscoped_error_handler

---@param handler fun(fib:any, err:any)
local function set_unscoped_error_handler(handler)
	assert(type(handler) == 'function', 'unscoped error handler must be a function')
	unscoped_error_handler = handler
end

----------------------------------------------------------------------
-- Current scope install/restore
----------------------------------------------------------------------

local function install_current_scope(s)
	local fib = current_fiber()
	if fib then
		local prev = fiber_scopes[fib]
		fiber_scopes[fib] = s
		return fib, prev
	end
	local prev = global_scope or root_scope or s
	global_scope = s
	return nil, prev
end

local function restore_current_scope(fib, prev)
	if fib then
		fiber_scopes[fib] = prev
	else
		global_scope = prev
	end
end

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------

local function copy_array(t)
	local out = {}
	for i = 1, #t do out[i] = t[i] end
	return out
end

local function snapshot_children_set(self)
	local snap = {}
	for ch in pairs(self._children) do snap[#snap + 1] = ch end
	return snap
end

local function oneshot_status_op(is_ready, os, get_st_v)
	return op.new_primitive(
		nil,
		function ()
			if is_ready() then
				local st, v = get_st_v()
				return true, st, v
			end
			return false
		end,
		function (suspension, wrap_fn)
			local cancel = os:add_waiter(function ()
				if suspension:waiting() then
					local st, v = get_st_v()
					suspension:complete(wrap_fn, st, v)
				end
			end)
			suspension:add_cleanup(cancel)
		end
	)
end

local function terminal_status(self)
	-- Failure takes precedence over cancellation.
	if self._primary_error ~= nil then return 'failed', self._primary_error end
	if self._cancelled then return 'cancelled', self._cancel_reason end
	return 'ok', nil
end

local function make_report(self, child_outcomes)
	return {
		id           = self._id,
		extra_errors = copy_array(self._extra_errors),
		children     = child_outcomes or {},
	}
end

local function should_reject_admission(self)
	return self._closed
		or self._cancelled
		or self._primary_error ~= nil
		or self._join_started
		or self._join_outcome ~= nil
end

----------------------------------------------------------------------
-- Observational status (non-blocking snapshot)
----------------------------------------------------------------------

--- Return a snapshot of this scope's current status.
---
--- This is intentionally observational: it does not synchronise or wait.
--- For waiting, use join_op()/cancel_op()/fault_op()/not_ok_op().
---
--- Returns:
---   'running',   nil
---   'failed',    primary_error
---   'cancelled', reason
---   'ok',        nil             (only once join has completed successfully)
---@return string st
---@return any v
function Scope:status()
	-- If join has completed, return the terminal state captured there.
	local out = self._join_outcome
	if out then return out.st, out.primary end

	-- Live view (pre-join).
	if self._primary_error ~= nil then return 'failed', self._primary_error end
	if self._cancelled then return 'cancelled', self._cancel_reason end
	return 'running', nil
end

--- The admission gate is deliberately not part of status(), because
--- "closed" is not a terminal outcome; it is simply "not admitting more work".
---
--- Returns:
---   'open',   nil
---   'closed', reason|nil
---@return string st
---@return any reason
function Scope:admission()
	if self._closed then return 'closed', self._close_reason end
	return 'open', nil
end

local function admission_error(self)
	-- Keep this intentionally simple and non-taxonomic.
	if self._join_outcome ~= nil or self._join_started then return 'scope is joining' end
	if self._primary_error ~= nil then return 'scope has failed' end
	if self._cancelled then return 'scope is cancelled' end
	if self._closed then return 'scope is closed' end
	return 'scope is not admitting work'
end

----------------------------------------------------------------------
-- Construction / root / current
----------------------------------------------------------------------

local function new_scope(parent)
	next_id = next_id + 1

	local s = setmetatable({
		_id       = next_id,
		_parent   = parent,
		_children = {},
		_order    = {},
		_wg       = waitgroup.new(),

		_closed = false,
		_close_os = oneshot.new(),

		_cancelled = false,
		_cancel_os = oneshot.new(),

		_extra_errors = {},
		_fault_os = oneshot.new(),

		_finalisers   = {},
		_join_started = false,
		_join_os      = oneshot.new(),
	}, Scope)

	if parent then
		parent._children[s] = true
		parent._order[#parent._order + 1] = s

		-- Downward cancellation propagates immediately to new children.
		if parent._cancelled then s:cancel(parent._cancel_reason) end
	end

	return s
end

local function root()
	if root_scope then return root_scope end

	root_scope   = new_scope(nil)
	global_scope = root_scope

	-- Error pump: route uncaught runtime errors to the owning scope when possible.
	runtime.spawn_raw(function ()
		while true do
			local fib, err = runtime.wait_fiber_error()
			-- Ignore cancellation sentinels.
			if not is_cancelled(err) then
				local s = fiber_scopes[fib]
				if s then
					s:_record_fault(err, { tag = 'unhandled_fibre_error' })
				else
					unscoped_error_handler(fib, err)
				end
			end
		end
	end)

	return root_scope
end

local function current()
	local fib = current_fiber()
	if fib then return fiber_scopes[fib] or root() end
	return global_scope or root()
end

----------------------------------------------------------------------
-- Child management (attachment)
----------------------------------------------------------------------

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
	if should_reject_admission(self) then return nil, admission_error(self) end

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

---@return Op -- yields: 'closed', reason
function Scope:close_op()
	return oneshot_status_op(
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

	-- Cancellation implies admission is closed (useful for accept loops and similar).
	self:close(reason)

	if not self._cancelled then
		self._cancelled = true
		self._cancel_reason = (reason ~= nil) and reason or (self._cancel_reason or 'scope cancelled')
		self._cancel_os:signal()
	elseif self._cancel_reason == nil and reason ~= nil then
		self._cancel_reason = reason
	end

	-- Cancel attached children (snapshot avoids mutation hazards).
	local snap = snapshot_children_set(self)
	for i = 1, #snap do snap[i]:cancel(self._cancel_reason) end
end

-- Record a fault in this scope. Cancellation escaping from bodies is control flow.
---@param err any
---@param _? table
function Scope:_record_fault(err, _)
	if is_cancelled(err) then
		self:cancel(cancel_reason(err))
		return
	end

	local e = err
	if type(e) ~= 'string' and type(e) ~= 'number' then
		e = tostring(e)
	end

	if self._primary_error == nil then
		self._primary_error = e
		self._fault_os:signal()
		-- Fail-fast: cancel the scope to stop sibling work.
		self:cancel(e)
	else
		self._extra_errors[#self._extra_errors + 1] = e
	end
end

---@return Op -- yields: 'cancelled', reason
function Scope:cancel_op()
	return oneshot_status_op(
		function () return self._cancelled end,
		self._cancel_os,
		function () return 'cancelled', self._cancel_reason end
	)
end

---@return Op -- yields: 'failed', primary
function Scope:fault_op()
	return oneshot_status_op(
		function () return self._primary_error ~= nil end,
		self._fault_os,
		function () return 'failed', self._primary_error end
	)
end

---@return Op -- yields: 'failed', primary | 'cancelled', reason
function Scope:not_ok_op()
	-- Re-check on wake so failure wins even if cancellation also became ready.
	return op.choice(self:fault_op(), self:cancel_op()):wrap(function ()
		if self._primary_error ~= nil then return 'failed', self._primary_error end
		return 'cancelled', self._cancel_reason
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
	if should_reject_admission(self) then return false, admission_error(self) end

	local args = pack(...)
	self._wg:add(1)

	runtime.spawn_raw(function ()
		local fib = current_fiber()
		local prev = fib and fiber_scopes[fib] or nil
		if fib then fiber_scopes[fib] = self end

		local ok, err = protected_call(function () return fn(self, unpack(args, 1, args.n)) end, tb_handler)

		if not ok then self:_record_fault(err, { tag = 'fibre_failed' }) end

		if fib then fiber_scopes[fib] = prev end
		self._wg:done()
	end)

	return true, nil
end

----------------------------------------------------------------------
-- Join (non-interruptible finalisation)
----------------------------------------------------------------------

function Scope:_finalise_join_body()
	-- Joining closes admission (but does not imply cancellation).
	self:close('joining')

	-- Snapshot children in attachment order.
	local children = copy_array(self._order)
	local child_outcomes = {}

	-- Drain spawned fibres.
	op.perform_raw(self._wg:wait_op())

	-- Join children in attachment order.
	for i = 1, #children do
		local ch = children[i]
		if ch and ch._parent == self then
			local st, primary, rep = op.perform_raw(ch:join_op())
			child_outcomes[#child_outcomes + 1] = {
				id      = ch._id,
				status  = st,
				primary = primary,
				report  = rep,
			}
			self:_remove_child(ch)
		end
	end

	-- Run finalisers (LIFO). Any finaliser error becomes a fault.
	local st, primary = terminal_status(self)
	local aborted = (st ~= 'ok')

	local fs = self._finalisers
	for i = #fs, 1, -1 do
		local f = fs[i]
		fs[i] = nil

		local ok, err = protected_call(function ()
			return f(aborted, st, (st == 'failed') and primary or nil)
		end, finaliser_tb_handler)

		if not ok then
			if is_cancelled(err) then
				self:_record_fault('finaliser raised cancellation: ' .. tostring(cancel_reason(err)),
					{ tag = 'finaliser_cancelled' })
			else
				self:_record_fault(err, { tag = 'finaliser_failed' })
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
		local ok, err = protected_call(function ()
			child_outcomes = self:_finalise_join_body()
		end, join_tb_handler)

		restore_current_scope(fib, prev)

		if not ok then
			self:_record_fault(err, { tag = 'join_failed' })
		end

		local st, primary = terminal_status(self)
		local rep = make_report(self, child_outcomes or {})

		self._join_outcome = { st = st, primary = primary, report = rep }
		self._join_os:signal()

		-- Avoid retaining completed children in long-lived parents.
		self:_detach_from_parent()
	end)
end

---@return Op -- yields: status, primary, report
function Scope:join_op()
	return op.new_primitive(
		nil,
		function ()
			local out = self._join_outcome
			if out then
				return true, out.st, out.primary, out.report
			end
			return false
		end,
		function (suspension, wrap_fn)
			local cancel = self._join_os:add_waiter(function ()
				if suspension:waiting() then
					local out = self._join_outcome
					if out then
						suspension:complete(wrap_fn, out.st, out.primary, out.report)
					else
						local st, primary = terminal_status(self)
						suspension:complete(wrap_fn, st, primary, make_report(self, {}))
					end
				end
			end)
			suspension:add_cleanup(cancel)
			self:_start_join_worker()
		end
	)
end

----------------------------------------------------------------------
-- Scope-aware op performance (status-first)
----------------------------------------------------------------------

local function assert_op_value(ev)
	if type(ev) ~= 'table' or getmetatable(ev) ~= op.Op then
		error(('scope: expected op, got %s (%s)'):format(type(ev), tostring(ev)), 3)
	end
end

---@param ev Op
---@return Op -- yields: 'ok', ... | 'failed', primary | 'cancelled', reason
function Scope:run_op(ev)
	assert_op_value(ev)

	return op.guard(function ()
		if self._primary_error ~= nil then return op.always('failed', self._primary_error) end
		if self._cancelled then return op.always('cancelled', self._cancel_reason) end

		local body = ev:wrap(function (...)
			if self._primary_error ~= nil then return 'failed', self._primary_error end
			if self._cancelled then return 'cancelled', self._cancel_reason end
			return 'ok', ...
		end)

		return op.choice(body, self:not_ok_op())
	end)
end

---@param ev Op
---@return '"ok"'|'"failed"'|'"cancelled"', ...
function Scope:try(ev)
	assert(runtime.current_fiber(), 'scope:try must be called from inside a fibre')
	return op.perform_raw(self:run_op(ev))
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

-- scope.run(body_fn, ...) -> (status, value_or_primary, report)
--   on ok:        'ok', packed_results, report
--   on not ok:    st,  primary,       report
local function run(body_fn, ...)
	assert(type(body_fn) == 'function', 'scope.run expects a function body')
	assert(runtime.current_fiber(), 'scope.run must be called from inside a fibre')

	local parent = current()
	local child, err = parent:child()

	-- Parent is not admitting; treat as cancelled boundary.
	if not child then return 'cancelled', err, make_report(parent, {}) end

	local args = pack(...)
	local fib, prev = install_current_scope(child)

	local ok, e
	local results

	ok, e = protected_call(function ()
		results = pack(body_fn(child, unpack(args, 1, args.n)))
	end, tb_handler)

	restore_current_scope(fib, prev)

	if not ok then child:_record_fault(e, { tag = 'run_body_failed' }) end

	local st, primary, rep = op.perform_raw(child:join_op())
	if st == 'ok' then return 'ok', (results or pack()), rep end

	return st, primary, rep
end

-- scope.with_op(build_op) -> Op producing (status, value_or_primary, report)
local function with_op(build_op)
	assert(type(build_op) == 'function', 'scope.with_op expects a function')

	return op.guard(function ()
		local parent = current()
		local child, err = parent:child()
		if not child then return op.always('cancelled', err, make_report(parent, {})) end

		local function acquire()
			local fib, prev = install_current_scope(child)
			return { fib = fib, prev = prev }
		end

		local function release(token, aborted)
			restore_current_scope(token.fib, token.prev)

			if aborted then
				-- Losing a choice is an external abort: cancel and join deterministically.
				child:cancel('aborted')
				safe.pcall(function () op.perform_raw(child:join_op()) end)
			end
		end

		local function use()
			local ok, body = protected_call(function () return build_op(child) end, tb_handler)

			if not ok then
				child:_record_fault(body, { tag = 'with_build_failed' })
				return op.always('failed', child._primary_error or body)
			end

			if type(body) ~= 'table' or getmetatable(body) ~= op.Op then
				local msg = ('scope.with_op: build_op must return an Op (got %s)'):format(type(body))
				child:_record_fault(msg, { tag = 'with_build_not_op' })
				return op.always('failed', msg)
			end

			return child:run_op(body)
		end

		return op.bracket(acquire, release, use):wrap(function (body_st, ...)
			local body_vals = pack(...)

			local join_st, join_primary, rep = op.perform_raw(child:join_op())

			if join_st ~= 'ok' then return join_st, join_primary, rep end
			if body_st == 'ok' then return 'ok', body_vals, rep end
			return body_st, body_vals[1], rep
		end)
	end)
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

return {
	root    = root,
	current = current,
	Scope   = Scope,

	run     = run,
	with_op = with_op,

	cancelled     = cancelled,
	is_cancelled  = is_cancelled,
	cancel_reason = cancel_reason,

	set_unscoped_error_handler = set_unscoped_error_handler,
	set_debug = set_debug
}

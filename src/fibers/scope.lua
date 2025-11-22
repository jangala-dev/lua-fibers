---
-- Scope module (structured concurrency).
--
-- Scopes form a tree of supervision domains.
--
-- Semantics:
--   - A single root scope exists for the process.
--   - Each fibre has an associated current scope (defaulting to root).
--   - scope.current() returns the current scope for the fibre,
--     or the process-wide current scope when not in a fibre.
--   - scope.run(fn, ...) runs fn in a fresh child scope in its *own*
--     fibre and then returns (status, error, ...body_results).
--   - s:spawn(fn, ...) spawns a new fibre whose current scope is s
--     for the duration of fn.
--   - scope.with_ev(build_ev) creates a first-class Event that
--     represents running a child scope whose body is build_ev(child).
--
-- Status model:
--   - "running"   : scope is active; children may be running.
--   - "ok"        : all fibres finished without uncaught errors and
--                   no explicit cancellation.
--   - "failed"    : at least one fibre ended with an uncaught error.
--   - "cancelled" : explicit cancellation, or abort via with_ev.
--
-- Failure handling:
--   - Uncaught Lua errors from any fibre are reported by runtime.
--   - The scope owning that fibre records a failure and cancels
--     its children (fail-fast).
--   - Callers observe this via status(), join_ev(), run(), etc.
--
-- Cancellation in events:
--   - Scope:run_ev(ev) races ev against a cancellation event.
--   - If cancellation wins, the event result is:
--       ok = false,
--       value1 = reason,
--       value2 = nil.
--
-- @module fibers.scope

local runtime   = require 'fibers.runtime'
local op        = require 'fibers.op'
local waitgroup = require 'fibers.waitgroup'
local cond         = require 'fibers.cond'

local safe = require 'coxpcall'

local unpack = rawget(table, "unpack") or _G.unpack
local pack   = rawget(table, "pack")   or function(...)
    return { n = select("#", ...), ... }
end

local Scope = {}
Scope.__index = Scope

-- Weak-keyed table mapping Fiber objects to their current Scope.
local fiber_scopes = setmetatable({}, { __mode = "k" })

-- Process-wide root scope and “current scope” when *not* in a fibre.
local root_scope
local global_scope

-- Handler for uncaught errors from fibres not associated with any Scope.
-- Default policy: treat them as failures of the root scope.
local function default_unscoped_error_handler(fib, err)
    if root_scope then
        root_scope:_record_failure(err)
    else
        -- Root not yet initialised: conservative fallback is to log.
        io.stderr:write("Unscoped fibre error before root initialised: " .. tostring(err) .. "\n")
    end
end

local unscoped_error_handler = default_unscoped_error_handler

local function set_unscoped_error_handler(handler)
    assert(type(handler) == "function", "unscoped error handler must be a function")
    unscoped_error_handler = handler
end

----------------------------------------------------------------------
-- Internal helpers
----------------------------------------------------------------------

-- Internal: current fibre object, or nil if not in a fibre.
local function current_fiber()
    return runtime.current_fiber()
end

-- Internal: create a new Scope with the given parent.
local function new_scope(parent)
    local s = setmetatable({
        _parent    = parent,
        _children  = setmetatable({}, { __mode = "k" }),  -- weak keys

        -- Status and failure tracking
        _status      = "running",
        _error       = nil,
        _failures    = {},
        failure_mode = "fail_fast",

        -- Concurrency tracking
        _wg      = waitgroup.new(),
        _defers  = {},

        -- Cancellation and join conditions
        _cancel_cond         = cond.new(),
        _join_cond           = cond.new(),

        _join_worker_started = false,
    }, Scope)

    if parent then
        -- store child as a weak key
        parent._children[s] = true
    end

    return s
end

--- Return the process-wide root scope.
local function root()
    if not root_scope then
        root_scope   = new_scope(nil)
        global_scope = root_scope

        runtime.spawn_raw(function()
            while true do
                local fib, err = runtime.wait_fiber_error()
                local s = fiber_scopes[fib]

                if s then
                    -- Fibres that were not started via Scope:spawn but
                    -- have an associated scope (e.g. internal helpers)
                    -- can still be treated as scope failures.
                    s:_record_failure(err)
                    -- Note: NO _wg:done() here.
                else
                    -- Completely unscoped fibres go to the global handler.
                    unscoped_error_handler(fib, err)
                end
            end
        end)
    end
    return root_scope
end

--- Return the current Scope.
-- Inside a fibre: the fibre's mapped scope, or the root if none.
-- Outside a fibre: the process-wide current scope, defaulting to root.
local function current()
    local fib = current_fiber()
    if fib then
        return fiber_scopes[fib] or root()
    end
    return global_scope or root()
end

----------------------------------------------------------------------
-- Scope methods: lifecycle and failure
----------------------------------------------------------------------

--- Internal: record a failure in this scope and cancel children.
function Scope:_record_failure(err)
    if self._status == "running" then
        self._status = "failed"
        self._error  = self._error or err
        -- Failure implies cancellation of children and done_ev.
        self:_propagate_cancel(self._error)
    else
        -- already "cancelled" or "failed": just record it
        local failures = self._failures
        failures[#failures + 1] = err
    end
end

--- Create a new child scope of this scope (no body, no current() change).
function Scope:new_child()
    return new_scope(self)
end

--- Register a deferred handler to run at scope close (LIFO).
--   handler :: function(Scope)
function Scope:defer(handler)
    local defers = self._defers
    defers[#defers + 1] = handler
end

function Scope:_propagate_cancel(reason)
    local r = reason or self._error or "scope cancelled"

    -- Wake done_ev waiters.
    self._cancel_cond:signal()

    -- Propagate to children (weak-key set).
    local children = self._children
    for child in pairs(children) do
        if child then
            child:cancel(r)
        end
    end
end

--- Cancel this scope and its children with an optional reason.
-- Idempotent: multiple calls are safe.
function Scope:cancel(reason)
    -- Once a scope is "ok", it is terminal: ignore.
    if self._status == "ok" then return end

    local r = reason or self._error or "scope cancelled"

    if self._status == "running" then
        self._status = "cancelled"
        if self._error == nil then
            self._error = r
        end
        -- Only now do we notify others.
        self:_propagate_cancel(r)
    end

    -- For "failed" or already "cancelled" scopes we do nothing here.
    -- Their propagation is handled by _record_failure or the first cancel.
end

--- Spawn a child fibre attached to this scope.
--   fn  :: function(Scope, ...): ()
--   ... :: arguments passed to fn
--
-- Behaviour:
--   * The new fibre inherits this scope as its current scope.
--   * The scope’s waitgroup is incremented on creation and decremented
--     when the fibre finishes, whether normally or due to an error.
--   * Any uncaught error in fn is caught by the scope machinery,
--     recorded as a failure of the scope that was current at the point
--     of error, and does not propagate as a Lua error.
--
-- The scope enters “failed” status on the first such error, with
-- cancellation propagated to any child scopes.
function Scope:spawn(fn, ...)
    assert(self._status == "running", "cannot spawn on a non-running scope")
    local args = pack(...)
    self._wg:add(1)

    runtime.spawn_raw(function()
        local fib  = current_fiber()
        local prev = fib and fiber_scopes[fib] or nil

        if fib then
            -- Dynamic current scope for this fibre.
            fiber_scopes[fib] = self
        end

        -- Run user code under this scope; catch uncaught errors.
        local ok, err = safe.pcall(fn, self, unpack(args, 1, args.n))

        if not ok then
            -- Attribute failure to the scope that was current at the point of error.
            local s = fib and (fiber_scopes[fib] or self) or self
            s:_record_failure(err)
        end

        -- Restore previous dynamic scope mapping.
        if fib then
            fiber_scopes[fib] = prev
        end

        -- Lifetime accounting: this fibre always belonged to `self`.
        self._wg:done()
    end)
end

--- Return this scope's parent, or nil for the root scope.
function Scope:parent()
    return self._parent
end

--- Return a shallow copy of this scope's children array.
function Scope:children()
    local out = {}
    local ch  = self._children or {}
    local i   = 1
    for child in pairs(ch) do
        out[i] = child
        i = i + 1
    end
    return out
end

--- Return this scope's status and primary error.
--   status :: "running" | "ok" | "failed" | "cancelled"
--   err    :: any | nil
function Scope:status()
    return self._status, self._error
end

--- Return a shallow copy of additional failures.
function Scope:failures()
    local out = {}
    local f   = self._failures or {}
    for i, v in ipairs(f) do
        out[i] = v
    end
    return out
end

----------------------------------------------------------------------
-- Join and done events
----------------------------------------------------------------------

-- Internal: start a join worker fibre that:
--   - waits for this scope's waitgroup to reach zero;
--   - sets final status to "ok" if still "running";
--   - runs defers; and
--   - signals _join_cond.
function Scope:_start_join_worker()
    if self._join_worker_started then return end
    self._join_worker_started = true

    runtime.spawn_raw(function()
        -- Attach this worker to the scope
        local fib = current_fiber()
        local prev = fib and fiber_scopes[fib]
        if fib then
            fiber_scopes[fib] = self
        end

        -- Wait for child fibres of this scope to complete.
        op.perform_raw(self._wg:wait_op())

        -- If still running and not cancelled/failed, mark as ok.
        if self._status == "running" then
            self._status = "ok"
            self._error  = nil
        end

        -- Run defers in LIFO order, protected.
        local defers = self._defers
        for i = #defers, 1, -1 do
            local f = defers[i]
            defers[i] = nil

            local ok, err = safe.pcall(f, self)
            if not ok then
                -- Treat defer failures as scope failures, but do not crash process.
                if self._status == "ok" then
                    self._status = "failed"
                    self._error  = self._error or err
                else
                    local failures = self._failures
                    failures[#failures + 1] = err
                end
            end
        end

        -- Restore previous scope mapping for this fibre
        if fib then
            fiber_scopes[fib] = prev
        end

        -- Signal join completion.
        self._join_cond:signal()
    end)
end

--- Event that fires once the scope has reached a terminal status.
-- Returns (status, error) when synchronised.
function Scope:join_ev()
    self:_start_join_worker()
    local ev = self._join_cond:wait_op()
    return ev:wrap(function()
        return self._status, self._error
    end)
end

--- Event that fires when the scope is cancelled or fails.
-- Returns the cancellation/failure reason when synchronised.
function Scope:done_ev()
    local ev = self._cancel_cond:wait_op()
    return ev:wrap(function()
        return self._error or "scope cancelled"
    end)
end

----------------------------------------------------------------------
-- Failure + cancellation wrapping for Events
----------------------------------------------------------------------

-- Internal: cancellation event used when running events under this scope.
-- Convention for cancellable events:
--   ok:boolean, value1_or_reason, value2
local function cancel_event(self)
    local ev = self._cancel_cond:wait_op()
    return ev:wrap(function()
        return false, self._error or "scope cancelled", nil
    end)
end

--- Transform an event to obey this scope's failure and cancellation policy.
-- Returns a new Event; does not perform it.
function Scope:run_ev(ev)
    -- Build a fresh event per synchronisation, so we can look at the
    -- scope status at sync time rather than at definition time.
    return op.guard(function()
        local status, err = self:status()

        -- If not running, short-circuit to cancellation result
        if status ~= "running" then
            return op.always(false, err or "scope cancelled", nil)
        end

        -- Normal path
        local cancel_ev = cancel_event(self)
        return op.choice(ev, cancel_ev)
    end)
end

--- Synchronise on an event under this scope.
-- Equivalent to op.perform_raw(self:run_ev(ev)).
function Scope:sync(ev)
    -- Scope-level synchronisation only occurs from inside a fiber
    assert(runtime.current_fiber(), "scope:sync must be called from inside a fiber (use fibers.run as an entry point)")

    -- Fast pre-check: do not start new work on a non-running scope.
    local status, err = self:status()
    if status ~= "running" then
        return false, err or "scope cancelled", nil
    end

    -- Perform the cancellable event
    local results = pack(op.perform_raw(self:run_ev(ev)))

    -- Re-check the scope status once the event has completed.
    status, err = self:status()

    -- If scope has failed/cancelled )treat as authoritative
    if status ~= "running" and status ~= "ok" then
        return false, err or "scope cancelled", nil
    end

    -- Scope still "running" or "ok"
    return unpack(results, 1, results.n)
end

----------------------------------------------------------------------
-- Scope as an *event*: scope.with_ev
----------------------------------------------------------------------

--- Event-level API: create a child scope whose body is an Event.
--
--   build_ev :: function(child_scope :: Scope) -> Event
--
-- The returned Event, when performed, will:
--   * create a child scope of scope.current();
--   * install it as the current scope while build_ev runs;
--   * run build_ev(child) as an Event under normal CML semantics
--     (whoever performs this Event controls cancellation etc.);
--   * on conclusion or abort, wait for child fibres, run defers,
--     and signal join_ev();
--   * propagate the inner Event's result or error as usual.
local function with_ev(build_ev)
    return op.guard(function()
        local parent = current()
        local child  = new_scope(parent)

        local function acquire()
            local fib = current_fiber()
            if fib then
                local prev = fiber_scopes[fib]
                fiber_scopes[fib] = child
                return { kind = "fiber", fib = fib, prev = prev }
            else
                local prev = global_scope or root()
                global_scope = child
                return { kind = "global", prev = prev }
            end
        end

        local function release(token, aborted)
            -- Restore the previous current scope.
            if token.kind == "fiber" then
                fiber_scopes[token.fib] = token.prev
            else
                global_scope = token.prev
            end

            -- If the event was aborted and the scope is still running,
            -- treat that as cancellation of the scope.
            if aborted and child._status == "running" then
                child._status = "cancelled"
                child._error  = child._error or "scope aborted"
                child:cancel(child._error)
            end

            -- Ensure the child scope is closed and defers run.
            op.perform_raw(child:join_ev())
        end

        local function use()
            -- Here the child is already installed as current().
            -- build_ev must return an Event, and must not perform it.
            return build_ev(child)
        end

        return op.bracket(acquire, release, use)
    end)
end

----------------------------------------------------------------------
-- scope.run: run a child scope in its own fibre
----------------------------------------------------------------------

--- Run a function inside a fresh child scope of the current scope.
--
--   body_fn :: function(Scope, ...): ...results...
--
-- Behaviour:
--   * A child scope of scope.current() is created.
--   * body_fn is run in a *separate fibre* with that child as the
--     dynamic current scope.
--   * All fibres spawned under that child are tracked via its waitgroup.
--   * Uncaught errors in body_fn (or its descendant fibres) are recorded
--     as failures of the child scope but do not escape as Lua errors.
--   * When the child scope reaches a terminal state (ok/failed/cancelled)
--     and its defers have run, this function returns:
--         status, error, ...results_from_body_fn...
--
--   status :: "ok" | "failed" | "cancelled"
--   error  :: primary error / cancellation reason, or nil on "ok".
--
-- The caller receives status information only; failure or cancellation
-- does not raise a Lua error here.
local function run(body_fn, ...)
    assert(runtime.current_fiber(), "scope.run must be called from inside a fiber")
    local parent = current()
    local child  = new_scope(parent)
    local args   = pack(...)

    -- store body results on the child scope
    child._result = nil

    -- body fibre under the child scope
    child:spawn(function(s)
        local res = pack(body_fn(s, unpack(args, 1, args.n)))
        s._result = res
    end)

    -- wait for the child scope to reach a terminal state
    local status, err = op.perform_raw(child:join_ev())

    local res = child._result
    if res then
        return status, err, unpack(res, 1, res.n)
    else
        return status, err
    end
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

return {
    root                       = root,
    current                    = current,
    run                        = run,
    with_ev                    = with_ev,
    Scope                      = Scope,
    set_unscoped_error_handler = set_unscoped_error_handler,
}

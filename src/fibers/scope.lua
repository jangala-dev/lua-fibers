-- fibers/scope.lua
---
-- Scope module (structured concurrency).
--
-- Provides a tree of Scope objects and a per-fiber “current scope”.
--
-- Semantics:
--   - A single root scope exists for the process.
--   - Each fiber has an associated current scope (defaulting to root).
--   - scope.current() returns the current scope for the fiber,
--     or the process-wide current scope when not in a fiber.
--   - scope.run(fn, ...) runs fn in a fresh child scope in the
--     current context (fiber or non-fiber), waits for its children,
--     runs defers, and then returns or raises based on scope status.
--   - s:spawn(fn, ...) spawns a new fiber whose current scope is s
--     for the duration of fn.
--   - scope.with_ev(build_ev) creates a *first-class Event* that
--     represents running a child scope whose body is build_ev(child).
--
-- Policies implemented:
--   - Status: "running" | "ok" | "failed" | "cancelled".
--   - Fail-fast failure propagation by default.
--   - Cancellation via Scope:cancel(reason) and a cancellation event.
--   - Child fibers tracked via a waitgroup; scope exit waits for them.
--   - Scope-level defers (LIFO) run at scope exit.
--   - Scope:run_ev(ev) wraps an Event with failure + cancellation.
--
-- @module fibers.scope

local runtime   = require 'fibers.runtime'
local op        = require 'fibers.op'
local waitgroup = require 'fibers.waitgroup'

local unpack = rawget(table, "unpack") or _G.unpack
local pack   = rawget(table, "pack") or function(...)
    return { n = select("#", ...), ... }
end

local Scope = {}
Scope.__index = Scope

-- Weak-keyed table mapping Fiber objects to their current Scope.
local fiber_scopes = setmetatable({}, { __mode = "k" })

-- Process-wide root scope and “current scope” when *not* in a fiber.
local root_scope
local global_scope

-- Internal: current fiber object, or nil if not in a fiber.
local function current_fiber()
    return runtime.current_fiber()
end

-- Internal: create a new Scope with the given parent.
local function new_scope(parent)
    local s = setmetatable({
        _parent    = parent,
        _children  = {},

        -- Status and failure tracking
        _status      = "running",    -- "running" | "ok" | "failed" | "cancelled"
        _error       = nil,          -- primary error / cancellation cause
        _failures    = {},           -- additional failures
        failure_mode = "fail_fast",  -- only fail_fast for now

        -- Concurrency tracking
        _wg      = waitgroup.new(),  -- waitgroup for child fibers
        _defers  = {},               -- LIFO list of deferred handlers

        -- Cancellation and join
        _cancel_cond = op.new_cond(), -- one-shot cond; signalled on cancel/failure
        _join_cond   = op.new_cond(), -- one-shot cond; signalled on scope exit
    }, Scope)

    if parent then
        local children = parent._children
        children[#children + 1] = s
    end
    return s
end

--- Return the process-wide root scope.
local function root()
    if not root_scope then
        root_scope   = new_scope(nil)
        global_scope = root_scope
    end
    return root_scope
end

--- Return the current Scope.
-- Inside a fiber: the fiber's mapped scope, or the root if none.
-- Outside a fiber: the process-wide current scope, defaulting to root.
local function current()
    local fib = current_fiber()
    if fib then
        return fiber_scopes[fib] or root()
    end
    return global_scope or root()
end

--- Internal helper: run fn(scope, ...) with 'scope' as current in this context.
-- Returns a packed result table: { n = ..., [1] = ok, [2..n] = values }.
local function with_scope(scope_obj, fn, ...)
    local fib = current_fiber()
    if fib then
        local prev = fiber_scopes[fib]
        fiber_scopes[fib] = scope_obj

        local res = pack(pcall(fn, scope_obj, ...))
        fiber_scopes[fib] = prev
        return res
    else
        local prev = global_scope or root()
        global_scope = scope_obj

        local res = pack(pcall(fn, scope_obj, ...))
        global_scope = prev
        return res
    end
end

----------------------------------------------------------------------
-- Core scope API
----------------------------------------------------------------------

--- Run a function inside a fresh child scope of the current scope.
-- Synchronous: runs in the current fiber or process context.
-- Returns the body_fn results on success.
-- On failure or cancellation, raises the scope's primary error.
--   body_fn :: function(Scope, ...): ...
local function run(body_fn, ...)
    local parent = current()
    local child  = new_scope(parent)

    -- Run the body with 'child' as current scope.
    local res = with_scope(child, body_fn, ...)
    local ok  = res[1]

    -- If the body itself raised (outside Event machinery),
    -- mark failure and cancel the scope (to trigger done_ev, etc.).
    if child._status == "running" and not ok then
        child._status = "failed"
        child._error  = res[2]
        child:cancel(child._error)   -- signals _cancel_cond, cancels children
    end

    -- Wait for child fibers to complete (even after fail_fast).
    op.perform(child._wg:wait_op())

    -- If still running and not cancelled/failed, mark as ok.
    if child._status == "running" then
        child._status = "ok"
        child._error  = nil
    end

    -- Run defers in LIFO order.
    local defers = child._defers
    for i = #defers, 1, -1 do
        local f = defers[i]
        defers[i] = nil
        pcall(f, child)
    end

    -- Signal join completion.
    child._join_cond.signal()

    -- Propagate outcome to caller.
    if child._status == "ok" then
        return unpack(res, 2, res.n)
    else
        error(child._error)
    end
end

--- Create a new child scope of this scope (no body, no current() change).
function Scope:new_child()
    return new_scope(self)
end

--- Register a deferred handler to run at scope exit (LIFO).
--   handler :: function(Scope)
function Scope:defer(handler)
    local defers = self._defers
    defers[#defers + 1] = handler
end

--- Cancel this scope and its children with an optional reason.
-- Idempotent: multiple calls are safe.
function Scope:cancel(reason)
    local r = reason or self._error or "scope cancelled"

    if self._status == "running" then
        self._status = "cancelled"
        if self._error == nil then
            self._error = r
        end
    elseif self._status == "ok" then
        -- Explicit cancellation after success: treat as cancelled.
        self._status = "cancelled"
        self._error  = r
    end

    -- Signal cancellation to any waiters.
    self._cancel_cond.signal()

    -- Propagate to children.
    local children = self._children
    for i = 1, #children do
        local c = children[i]
        if c then
            c:cancel(r)
        end
    end
end

--- Spawn a child fiber attached to this scope.
--   fn  :: function(Scope, ...): ()
--   ... :: arguments passed to fn
--
-- Fail-fast semantics:
--   - If fn raises, this scope's status becomes "failed", its primary
--     error is set (if not already), and cancel() is invoked.
function Scope:spawn(fn, ...)
    local args = { ... }
    self._wg:add(1)

    runtime.spawn(function()
        local fib  = current_fiber()
        local prev = fib and fiber_scopes[fib] or nil
        if fib then
            fiber_scopes[fib] = self
        end

        local ok, err
        if #args > 0 then
            ok, err = pcall(fn, self, unpack(args))
        else
            ok, err = pcall(fn, self)
        end

        if fib then
            fiber_scopes[fib] = prev
        end

        if not ok then
            -- Fail-fast policy: record failure and cancel the scope.
            if self._status == "running" then
                self._status = "failed"
                if self._error == nil then
                    self._error = err
                end
                self:cancel(self._error)
            else
                -- Additional failures are recorded but do not change
                -- the primary status at this stage.
                local failures = self._failures
                failures[#failures + 1] = err
            end
            -- Do not rethrow; errors are handled via scope status.
        end

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
    for i, child in ipairs(ch) do
        out[i] = child
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

--- Event that fires once the scope has reached a terminal status.
-- Returns (status, error) when synchronised.
function Scope:join_ev()
    local ev = self._join_cond.wait_op()
    return ev:wrap(function()
        return self._status, self._error
    end)
end

--- Event that fires when the scope is cancelled or fails.
-- Returns the cancellation/failure reason when synchronised.
function Scope:done_ev()
    local ev = self._cancel_cond.wait_op()
    return ev:wrap(function()
        return self._error or "scope cancelled"
    end)
end

----------------------------------------------------------------------
-- Failure + cancellation wrapping for Events
----------------------------------------------------------------------

-- Internal: cancellation event used when running events under this scope.
local function cancel_event(self)
    local ev = self._cancel_cond.wait_op()
    return ev:wrap(function()
        error(self._error or "scope cancelled")
    end)
end

--- Transform an event to obey this scope's failure and cancellation policy.
-- Returns a new Event; does not perform it.
function Scope:run_ev(ev)
    local cancel_ev = cancel_event(self)
    return op.choice(ev, cancel_ev)
end

--- Synchronise on an event under this scope.
-- Equivalent to op.perform(self:run_ev(ev)).
function Scope:sync(ev)
    return op.perform(self:run_ev(ev))
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
--     (i.e. whoever performs this Event controls cancellation etc.);
--   * on conclusion or abort, wait for child fibers, run defers,
--     and signal join_ev();
--   * propagate the inner Event's result or error.
local function with_ev(build_ev)
    return op.guard(function()
        local parent = current()
        local child  = new_scope(parent)

        -- bracket acquires "current scope = child", and guarantees
        -- we restore the previous current scope and run scope cleanup
        -- exactly once, whether the event wins, errors, or is aborted.
        local function acquire()
            -- Install child as current, remember what to restore.
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

            -- Wait for child fibers to complete.
            op.perform(child._wg:wait_op())

            -- If still running and not cancelled/failed, mark as ok.
            if child._status == "running" then
                child._status = "ok"
                child._error  = nil
            end

            -- Run defers in LIFO order.
            local defers = child._defers
            for i = #defers, 1, -1 do
                local f = defers[i]
                defers[i] = nil
                pcall(f, child)
            end

            -- Signal join completion.
            child._join_cond.signal()
        end

        local function use()
            -- Here the child is already installed as current().
            -- build_ev must return an Event, and must not perform it.
            local ok, ev = pcall(build_ev, child)
            if not ok then
                local ex = ev
                -- mark failure & cancel the scope
                if child._status == "running" then
                    child._status = "failed"
                    child._error  = ex
                    child:cancel(ex)
                end
                error(ex)
            end
            -- The inner event itself may fail; that is handled by whoever
            -- is performing this with_ev event (typically via Scope:run_ev).
            return ev
        end

        return op.bracket(acquire, release, use)
    end)
end

return {
    root     = root,
    current  = current,
    run      = run,
    with_ev  = with_ev,
    Scope    = Scope,
}

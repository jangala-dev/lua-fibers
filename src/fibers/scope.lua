---
-- Structured concurrency scopes.
--
-- Scopes form a tree of supervision domains with fail-fast semantics.
-- Each fiber runs within a current scope; cancellation and failures
-- are tracked per-scope and propagated to children.
---@module 'fibers.scope'

local runtime   = require 'fibers.runtime'
local op        = require 'fibers.op'
local waitgroup = require 'fibers.waitgroup'
local cond      = require 'fibers.cond'
local safe      = require 'coxpcall'

local unpack = rawget(table, "unpack") or _G.unpack
local pack   = rawget(table, "pack")   or function(...)
    return { n = select("#", ...), ... }
end

---@alias ScopeStatus "running"|"ok"|"failed"|"cancelled"

--- Supervision scope for structured concurrency.
---@class Scope
---@field _parent Scope|nil
---@field _children table<Scope, boolean>   # weak-key set of child scopes
---@field _status ScopeStatus
---@field _error any
---@field _failures any[]
---@field failure_mode string               # e.g. "fail_fast"
---@field _wg Waitgroup
---@field _defers fun(self: Scope)[]        # LIFO defers
---@field _cancel_cond Cond
---@field _join_cond Cond
---@field _join_worker_started boolean
---@field _result table|nil                 # used by run()
local Scope = {}
Scope.__index = Scope

-- Weak-keyed table mapping Fiber objects to their current Scope.
---@type table<Fiber, Scope>
local fiber_scopes = setmetatable({}, { __mode = "k" })

-- Process-wide root scope and “current scope” when not in a fiber.
---@type Scope|nil
local root_scope
---@type Scope|nil
local global_scope

-- Handler for uncaught errors from fibers not associated with any Scope.
---@param _ any
---@param err any
local function default_unscoped_error_handler(_, err)
    if root_scope then
        root_scope:_record_failure(err)
    else
        io.stderr:write("Unscoped fiber error before root initialised: " .. tostring(err) .. "\n")
    end
end

---@type fun(fib: any, err: any)
local unscoped_error_handler = default_unscoped_error_handler

--- Set the handler for uncaught errors in fibers that have no scope.
---@param handler fun(fib: Fiber, err: any)
local function set_unscoped_error_handler(handler)
    assert(type(handler) == "function", "unscoped error handler must be a function")
    unscoped_error_handler = handler
end

----------------------------------------------------------------------
-- Internal helpers
----------------------------------------------------------------------

--- Internal: current fiber object, or nil if not in a fiber.
---@return Fiber|nil
local function current_fiber()
    return runtime.current_fiber()
end

--- Internal: create a new Scope with the given parent.
---@param parent Scope|nil
---@return Scope
local function new_scope(parent)
    local s = setmetatable({
        _parent    = parent,
        _children  = setmetatable({}, { __mode = "k" }),

        _status      = "running",
        _error       = nil,
        _failures    = {},
        failure_mode = "fail_fast",

        _wg      = waitgroup.new(),
        _defers  = {},

        _cancel_cond         = cond.new(),
        _join_cond           = cond.new(),
        _join_worker_started = false,
    }, Scope)

    if parent then
        parent._children[s] = true
    end

    return s
end

--- Return the process-wide root scope, creating it if needed.
---@return Scope
local function root()
    if not root_scope then
        root_scope   = new_scope(nil)
        global_scope = root_scope

        -- Error pump: attribute uncaught fiber errors to scopes.
        runtime.spawn_raw(function()
            while true do
                local fib, err = runtime.wait_fiber_error()
                local s = fiber_scopes[fib]

                if s then
                    s:_record_failure(err)
                else
                    unscoped_error_handler(fib, err)
                end
            end
        end)
    end
    return root_scope
end

--- Return the current Scope.
--- Inside a fiber: the fiber's scope or the root if none.
--- Outside a fiber: the process-wide current scope, defaulting to root.
---@return Scope
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
---@param err any
function Scope:_record_failure(err)
    if self._status == "running" then
        self._status = "failed"
        self._error  = self._error or err
        self:_propagate_cancel(self._error)
    else
        local failures = self._failures
        failures[#failures + 1] = err
    end
end

--- Create a new child scope of this scope (no body, no current() change).
---@return Scope
function Scope:new_child()
    return new_scope(self)
end

--- Register a deferred handler to run when the scope closes (LIFO).
---@param handler fun(self: Scope)
function Scope:defer(handler)
    local defers = self._defers
    defers[#defers + 1] = handler
end

---@param reason any|nil
function Scope:_propagate_cancel(reason)
    local r = reason or self._error or "scope cancelled"

    self._cancel_cond:signal()

    local children = self._children
    for child in pairs(children) do
        if child then
            child:cancel(r)
        end
    end
end

--- Cancel this scope and its children with an optional reason.
--- Idempotent; subsequent calls after terminal success are ignored.
---@param reason any|nil
function Scope:cancel(reason)
    if self._status == "ok" then return end

    local r = reason or self._error or "scope cancelled"

    if self._status == "running" then
        self._status = "cancelled"
        if self._error == nil then
            self._error = r
        end
        self:_propagate_cancel(r)
    end
end

--- Spawn a child fiber attached to this scope.
--- The fiber runs fn(self, ...) with this scope as its current scope.
---@param fn fun(s: Scope, ...): any
---@param ... any
function Scope:spawn(fn, ...)
    assert(self._status == "running", "cannot spawn on a non-running scope")
    local args = pack(...)
    self._wg:add(1)

    runtime.spawn_raw(function()
        local fib  = current_fiber()
        local prev = fib and fiber_scopes[fib] or nil

        if fib then
            fiber_scopes[fib] = self
        end

        local ok, err = safe.pcall(fn, self, unpack(args, 1, args.n))

        if not ok then
            local s = fib and (fiber_scopes[fib] or self) or self
            s:_record_failure(err)
        end

        if fib then
            fiber_scopes[fib] = prev
        end

        self._wg:done()
    end)
end

--- Return this scope's parent, or nil for the root scope.
---@return Scope|nil
function Scope:parent()
    return self._parent
end

--- Return a shallow copy of this scope's children.
---@return Scope[]
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

--- Return this scope's status and primary error (if any).
---@return ScopeStatus status
---@return any err
function Scope:status()
    return self._status, self._error
end

--- Return a shallow copy of additional failures recorded on this scope.
---@return any[]
function Scope:failures()
    local out = {}
    local f   = self._failures or {}
    for i, v in ipairs(f) do
        out[i] = v
    end
    return out
end

----------------------------------------------------------------------
-- Join and done ops
----------------------------------------------------------------------

-- Internal: start a join worker that awaits children, runs defers and
-- finalises status, then signals _join_cond.
function Scope:_start_join_worker()
    if self._join_worker_started then return end
    self._join_worker_started = true

    runtime.spawn_raw(function()
        local fib  = current_fiber()
        local prev = fib and fiber_scopes[fib]
        if fib then
            fiber_scopes[fib] = self
        end

        op.perform_raw(self._wg:wait_op())

        if self._status == "running" then
            self._status = "ok"
            self._error  = nil
        end

        local defers = self._defers
        for i = #defers, 1, -1 do
            local f = defers[i]
            defers[i] = nil

            local ok, err = safe.pcall(f, self)
            if not ok then
                if self._status == "ok" then
                    self._status = "failed"
                    self._error  = self._error or err
                else
                    local failures = self._failures
                    failures[#failures + 1] = err
                end
            end
        end

        if fib then
            fiber_scopes[fib] = prev
        end

        self._join_cond:signal()
    end)
end

--- Op that fires once the scope has reached a terminal status.
--- Returns (status, error) when performed.
---@return Op
function Scope:join_op()
    self:_start_join_worker()
    local ev = self._join_cond:wait_op()
    return ev:wrap(function()
        return self._status, self._error
    end)
end

--- Op that fires when the scope is cancelled or fails.
--- Returns the cancellation or failure reason when performed.
---@return Op
function Scope:done_op()
    local ev = self._cancel_cond:wait_op()
    return ev:wrap(function()
        return self._error or "scope cancelled"
    end)
end

----------------------------------------------------------------------
-- Failure and cancellation wrapping for Ops
----------------------------------------------------------------------

--- Internal: build a cancellation op for this scope.
--- The particular return values are ignored by Scope:sync/Scope:perform;
--- only the fact that this op can win in a choice is important.
---@param self Scope
---@return Op
local function cancel_op(self)
    local ev = self._cancel_cond:wait_op()
    return ev:wrap(function()
        return false, self._error or "scope cancelled", nil
    end)
end

--- Wrap an op so that it observes this scope's cancellation and failure state.
--- Returns a new Op; does not perform it.
---@param ev Op
---@return Op
function Scope:run_op(ev)
    return op.guard(function()
        local this_cancel_op = cancel_op(self)
        return op.choice(ev, this_cancel_op)
    end)
end

--- Perform an op under this scope, obeying its cancellation rules.
--- On success returns true followed by the op's result values.
--- On failure or cancellation returns false and an error value.
---@param ev Op
---@return boolean ok
---@return any ...
function Scope:sync(ev)
    assert(runtime.current_fiber(),
        "scope:sync must be called from inside a fiber (use fibers.run as an entry point)")

    local status, err = self:status()
    if status ~= "running" then
        return false, err or "scope cancelled"
    end

    local results = pack(op.perform_raw(self:run_op(ev)))

    status, err = self:status()
    if status ~= "running" and status ~= "ok" then
        return false, err or "scope cancelled"
    end

    return true, unpack(results, 1, results.n)
end

--- Perform an op under this scope, raising on failure or cancellation.
--- On success returns the op's result values.
---@param ev Op
---@return any ...
function Scope:perform(ev)
    -- sync does the fibre assertion and fail-fast logic
    local results = pack(self:sync(ev))

    local ok = results[1]
    if not ok then
        -- results[2] is the error value from sync
        error(results[2])
    end

    return unpack(results, 2, results.n)
end

----------------------------------------------------------------------
-- Scope as an op: with_op
----------------------------------------------------------------------

--- Create an Op that runs a child scope whose body is an Op.
--- build_op(child_scope) must return an Op; the child scope is current()
--- for the duration of the body.
---@param build_op fun(child_scope: Scope): Op
---@return Op
local function with_op(build_op)
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

        ---@param token { kind: "fiber"|"global", fib?: any, prev: Scope }
        ---@param aborted boolean
        local function release(token, aborted)
            if token.kind == "fiber" then
                fiber_scopes[token.fib] = token.prev
            else
                global_scope = token.prev
            end

            if aborted and child._status == "running" then
                child._status = "cancelled"
                child._error  = child._error or "scope aborted"
                child:cancel(child._error)
            end

            op.perform_raw(child:join_op())
        end

        local function use()
            return build_op(child)
        end

        return op.bracket(acquire, release, use)
    end)
end

----------------------------------------------------------------------
-- scope.run: run a child scope in its own fiber
----------------------------------------------------------------------

--- Run a function inside a fresh child scope of the current scope.
---
--- The body runs as body_fn(child_scope, ...).
--- Returns:
---   status :: "ok" | "failed" | "cancelled"
---   err    :: primary error or cancellation reason (nil on "ok")
---   ...    :: any results returned from body_fn
---@param body_fn fun(s: Scope, ...): ...
---@param ... any
---@return ScopeStatus status
---@return any err
---@return any ...
local function run(body_fn, ...)
    assert(runtime.current_fiber(), "scope.run must be called from inside a fiber")
    local parent = current()
    local child  = new_scope(parent)
    local args   = pack(...)

    child._result = nil

    child:spawn(function(s)
        local res = pack(body_fn(s, unpack(args, 1, args.n)))
        s._result = res
    end)

    local status, err = op.perform_raw(child:join_op())

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
    with_op                    = with_op,
    Scope                      = Scope,
    set_unscoped_error_handler = set_unscoped_error_handler,
}

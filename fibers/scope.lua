-- fibers/scope.lua
---
-- Basic scope module (stage 2).
-- Provides a tree of Scope objects and a per-fibre “current scope”.
--
-- At this stage:
--   - A single root scope exists for the process.
--   - Each fibre may have an associated current scope.
--   - scope.current() returns the current scope for the fibre,
--     or the process-wide current scope when not in a fibre.
--   - scope.run(fn, ...) runs fn in a fresh child scope in the
--     current context (fibre or non-fibre).
--   - scope.root():spawn(fn, ...) spawns a new fibre whose current
--     scope is that scope for the duration of fn.
--
-- Policies (failure, cancellation, resource limits) are *not* yet
-- implemented; they will be added in later stages.
--
-- @module fibers.scope

local runtime = require 'fibers.runtime'

local unpack = rawget(table, "unpack") or _G.unpack
local pack   = rawget(table, "pack") or function(...)
    return { n = select("#", ...), ... }
end

local Scope = {}
Scope.__index = Scope

-- Weak-keyed table mapping Fiber objects to their current Scope.
local fiber_scopes = setmetatable({}, { __mode = "k" })

-- Process-wide root scope and “current scope” when *not* in a fibre.
local root_scope
local global_scope

-- Internal: create a new Scope with the given parent.
local function new_scope(parent)
    local s = setmetatable({
        _parent   = parent,
        _children = {},
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

-- Internal: current fibre object, or nil if not in a fibre.
local function current_fiber()
    if runtime.current_fiber then
        return runtime.current_fiber()
    end
    return nil
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

--- Internal helper: run fn(scope, ...) with 'scope' as current in this context.
local function with_scope(scope, fn, ...)
    local fib = current_fiber()
    if fib then
        local prev = fiber_scopes[fib]
        fiber_scopes[fib] = scope

        local res = pack(pcall(fn, scope, ...))
        fiber_scopes[fib] = prev
        if not res[1] then error(res[2]) end
        return unpack(res, 2, res.n)
    else
        local prev = global_scope or root()
        global_scope = scope

        local res = pack(pcall(fn, scope, ...))
        global_scope = prev
        if not res[1] then error(res[2]) end
        return unpack(res, 2, res.n)
    end
end

--- Run a function inside a fresh child scope of the current scope.
-- Synchronous: runs in the current fibre or process context.
--   body_fn :: function(Scope, ...): ...
local function run(body_fn, ...)
    local parent = current()
    local child  = new_scope(parent)
    return with_scope(child, body_fn, ...)
end

--- Create a new child scope of this scope.
-- Does not change the current scope or run any code.
function Scope:new_child()
    return new_scope(self)
end

--- Spawn a child fibre attached to this scope.
--   fn  :: function(Scope, ...): ()
--   ... :: arguments passed to fn
--
-- The new fibre's current scope is set to 'self' for the duration
-- of fn, and any previous mapping for that fibre (normally none)
-- is restored afterwards.
function Scope:spawn(fn, ...)
    local args = { ... }
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
            -- Stage 2: preserve existing behaviour (unhandled errors
            -- still crash the process via runtime/Fiber:resume).
            error(err)
        end
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

return {
    root    = root,
    current = current,
    run     = run,
    Scope   = Scope,
}

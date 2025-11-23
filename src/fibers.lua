-- fibers.lua
-- Top-level facade for the fibers library.
--
-- Provides a small, convenient surface over the lower-level modules:
--   - runtime    (scheduler and fibers),
--   - op         (CML engine),
--   - scope      (structured concurrency),
--   - primitives (sleep, channel, etc.).
--
---@module 'fibers'

local Op        = require 'fibers.op'
local Runtime   = require 'fibers.runtime'
local Scope     = require 'fibers.scope'
local Performer = require 'fibers.performer'

local unpack = rawget(table, "unpack") or _G.unpack
local pack   = rawget(table, "pack")   or function(...)
    return { n = select("#", ...), ... }
end

----------------------------------------------------------------------
-- Core entry points
----------------------------------------------------------------------

--- Run a main function under the scheduler's root scope.
--
-- main_fn is called as main_fn(scope, ...).
--
-- Returns:
--   status :: "ok" | "failed" | "cancelled"
--   err    :: primary error / cancellation reason, or nil on "ok".
---@param main_fn fun(s: Scope, ...): any
---@param ... any
---@return ScopeStatus status
---@return any err
---@return any ...
local function run(main_fn, ...)
    assert(not Runtime.current_fiber(),
       "fibers.run must not be called from inside a fiber")
    local root = Scope.root()
    local args = pack(...)

    local status, err
    local results  -- may be nil or a packed table

    root:spawn(function()
        -- scope.run creates a child scope of the current scope,
        -- runs main_fn(body_scope, ...) in its own fiber, and returns
        -- (status, err, ...results_from_body_fn...).
        local packed = pack(Scope.run(main_fn, unpack(args, 1, args.n or #args)))
        status, err  = packed[1], packed[2]

        if packed.n > 2 then
            -- Preserve any results from main_fn, including nils.
            local out = { n = packed.n - 2 }
            local j   = 1
            for i = 3, packed.n do
                out[j] = packed[i]
                j = j + 1
            end
            results = out
        else
            results = nil
        end

        -- In all cases, stop the scheduler so runtime.main() returns.
        Runtime.stop()
    end)

    -- Drive the scheduler until stopped by the main scope.
    Runtime.main()

    if results then
        return status, err, unpack(results, 1, results.n or #results)
    else
        return status, err
    end
end

----------------------------------------------------------------------
-- Spawn
----------------------------------------------------------------------

--- Spawn a fiber under the current scope.
---
--- fn is called as fn(scope, ...).
---@param fn fun(s: Scope, ...): any
---@param ... any
local function spawn(fn, ...)
    local s = Scope.current()
    return s:spawn(fn, ...)
end

return {
    spawn = spawn,
    run   = run,

    perform = Performer.perform,

    now = Runtime.now,

    choice     = Op.choice,
    guard      = Op.guard,
    with_nack  = Op.with_nack,
    always     = Op.always,
    never      = Op.never,
    bracket    = Op.bracket,

    -- Higher-level choice helpers
    race           = Op.race,
    first_ready    = Op.first_ready,
    named_choice   = Op.named_choice,
    boolean_choice = Op.boolean_choice,

    -- Scope utilities re-exported
    run_scope                  = Scope.run,
    scope_op                   = Scope.with_op,
    set_unscoped_error_handler = Scope.set_unscoped_error_handler,
}

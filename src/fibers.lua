-- fibers.lua
-- Top-level facade for the fibers library.
--
-- Provides a small, convenient surface over the lower-level modules:
--   - runtime    (scheduler and fibers),
--   - op         (CML engine),
--   - scope      (structured concurrency),
--   - primitives (sleep, channel, etc.).
--
-- Scopes currently carry no policies; they form a tree and track the
-- current scope per fiber.
--
-- @module fibers

local Op   = require 'fibers.op'
local Runtime   = require 'fibers.runtime'
local Scope = require 'fibers.scope'
local Performer = require 'fibers.performer'

local unpack = rawget(table, "unpack") or _G.unpack
local pack   = rawget(table, "pack")   or function(...)
    return { n = select("#", ...), ... }
end

local fibers = {}

----------------------------------------------------------------------
-- Core entry points
----------------------------------------------------------------------

--- Perform an event under the current scope (if any).
-- Delegates to the scope-aware performer.
fibers.perform = Performer.perform

--- Monotonic time source from the underlying scheduler.
fibers.now = Runtime.now

fibers.choice = Op.choice

--- Run a main function under the scheduler's root scope.
--
--   main_fn :: function(Scope, ...): ...results...
--
-- Behaviour:
--   * A process-wide root scope is created on first use.
--   * A child scope of that root is created via scope.run.
--   * main_fn is run in its own fibre under that child scope.
--   * All fibres spawned under that child are tracked.
--   * When the child scope has closed (ok/failed/cancelled, defers run),
--     this function returns:
--         status, err, ...results_from_main_fn...
--
--   status :: "ok" | "failed" | "cancelled"
--   err    :: primary error / cancellation reason, or nil on "ok".
--
-- This function does not exit the process. It stops the scheduler and
-- hands the status and error back to the caller.
function fibers.run(main_fn, ...)
    assert(not Runtime.current_fiber(),
       "fibers.run must not be called from inside a fiber")
    local root = Scope.root()
    local args = pack(...)

    local status, err
    local results      -- may be nil or a packed table

    root:spawn(function()
        -- scope.run creates a child scope of the current scope,
        -- runs main_fn(body_scope, ...) in its own fibre, and returns
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

--- Spawn a fibre under the current scope.
--
--   fn  :: function(Scope, ...): ()
--   ... :: arguments passed to fn
function fibers.spawn(fn, ...)
    local s = Scope.current()
    return s:spawn(fn, ...)
end

return fibers

-- fibers.lua
---
-- Top-level façade for the fibers library.
-- Provides a small, convenient surface over the lower-level modules:
--   - runtime (scheduler and fibres),
--   - op (CML engine),
--   - scope (structured concurrency),
--   - primitives (sleep, channel, etc.).
--
-- At this stage, scopes carry no policies; they simply form a tree
-- and track the current scope per fibre.
--
-- @module fibers

local runtime   = require 'fibers.runtime'
local scope_mod = require 'fibers.scope'
local performer = require 'fibers.performer'

local sleep_mod = require 'fibers.sleep'
local channel   = require 'fibers.channel'
local op        = require 'fibers.op'

local unpack = rawget(table, "unpack") or _G.unpack

local fibers = {}

----------------------------------------------------------------------
-- Core execution
----------------------------------------------------------------------

--- Perform an event under the current scope.
fibers.perform = performer.perform

--- Current monotonic time.
fibers.now = runtime.now

--- Run a main function under the scheduler's root scope.
--   main_fn :: function(Scope, ...): ()
function fibers.run(main_fn, ...)
    local root = scope_mod.root()
    local args = { ... }

    -- Spawn an initial fibre under the root scope.
    root:spawn(function(s)
        main_fn(s, unpack(args))
        -- When main_fn returns, stop the scheduler loop.
        runtime.stop()
    end)

    -- Drive the scheduler until stop() is called.
    runtime.main()
end

--- Spawn a fibre under the current scope.
--   fn :: function(Scope, ...): ()
function fibers.spawn(fn, ...)
    local s = scope_mod.current()
    return s:spawn(fn, ...)
end

----------------------------------------------------------------------
-- Common primitives
----------------------------------------------------------------------

fibers.sleep   = sleep_mod.sleep
fibers.channel = channel.new

----------------------------------------------------------------------
-- Scopes and ops for advanced use
----------------------------------------------------------------------

fibers.scope = scope_mod
fibers.op    = op

-- Re-export a few core CML combinators for convenience.
fibers.choice    = op.choice
fibers.guard     = op.guard
fibers.with_nack = op.with_nack
fibers.always    = op.always
fibers.never     = op.never

return fibers

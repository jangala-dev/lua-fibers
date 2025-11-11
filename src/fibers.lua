-- fibers.lua
---
-- Top-level facade for the fibers library.
-- Provides a small, convenient surface over the lower-level modules:
--   - runtime (scheduler and fibers),
--   - op (CML engine),
--   - scope (structured concurrency),
--   - primitives (sleep, channel, etc.).
--
-- At this stage, scopes carry no policies; they simply form a tree
-- and track the current scope per fiber.
--
-- @module fibers

local runtime   = require 'fibers.runtime'
local scope_mod = require 'fibers.scope'
local performer = require 'fibers.performer'

local sleep_mod = require 'fibers.sleep'
local channel   = require 'fibers.channel'
local op        = require 'fibers.op'

local unpack = rawget(table, "unpack") or _G.unpack
local pack   = rawget(table, "pack") or function(...)
    return { n = select("#", ...), ... }
end

local fibers = {}

-- Perform an event under the current scope.
fibers.perform = performer.perform

fibers.now = runtime.now

--- Run a main function under the scheduler's root scope.
--   main_fn :: function(Scope, ...): ()
function fibers.run(main_fn, ...)
    local root = scope_mod.root()
    local args = { ... }

    root:spawn(function()
        -- Run main_fn inside a child scope of the current scope (root).
        local res = pack(
            pcall(function()
                return scope_mod.run(main_fn, unpack(args))
            end)
        )
        -- In all cases, stop the scheduler so runtime.main() returns.
        runtime.stop()
        -- If the main scope failed, treat as fatal for the process.
        if not res[1] then
            print(unpack(res, 2, res.n))
            os.exit(255)
        end
    end)

    runtime.main()
end

--- Spawn a fiber under the current scope.
function fibers.spawn(fn, ...)
    local s = scope_mod.current()
    return s:spawn(fn, ...)
end

fibers.sleep   = sleep_mod.sleep
fibers.channel = channel.new

fibers.scope = scope_mod
fibers.op    = op

fibers.choice    = op.choice
fibers.guard     = op.guard
fibers.with_nack = op.with_nack
fibers.always    = op.always
fibers.never     = op.never

return fibers

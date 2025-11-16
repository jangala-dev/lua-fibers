-- fibers/runtime.lua
---
-- Runtime module.
-- Wraps the global scheduler and fiber machinery.
-- This is a low-level module; most code should go via higher-level APIs.
-- @module fibers.runtime

local sched = require 'fibers.sched'

local function id(...)
    return ...
end

-- Queue of uncaught fibre errors to be consumed by supervisors.
local error_queue   = {}
local error_waiters = {}

-- Task object used to wake a fibre waiting for an error.
local WaiterTask = {}
WaiterTask.__index = WaiterTask

function WaiterTask:run()
    -- Resume the waiting fibre with (wrap, fiber, err).
    self.waiter:resume(id, self.err_fiber, self.err)
end

local _current_fiber
local current_scheduler = sched.new()

--- Fiber class
-- Represents a single fiber, or lightweight thread.
-- @type Fiber
local Fiber = {}
Fiber.__index = Fiber

--- Spawns a new fiber.
-- @function spawn
-- @tparam function fn The function to run in the new fiber.
local function spawn(fn)
    -- Capture the traceback
    local tb = debug.traceback("", 2):match("\n[^\n]*\n(.*)") or ""
    -- If we're inside another fiber, append the traceback to the parent's traceback
    if _current_fiber and _current_fiber.traceback then
        tb = tb .. "\n" .. _current_fiber.traceback
    end

    current_scheduler:schedule(
        setmetatable({
            coroutine = coroutine.create(fn),
            alive     = true,
            sockets   = {},
            traceback = tb
        }, Fiber)
    )
end

--- Resumes execution of the fiber.
-- If the fiber is already dead, this will throw an error.
-- @tparam vararg ... The arguments to pass to the fiber.
function Fiber:resume(wrap, ...)
    assert(self.alive, "dead fiber")                     -- checks that the fiber is alive
    local saved_current_fiber = _current_fiber            -- shift the old current fiber into a safe place
    _current_fiber = self                                 -- we are the new current fiber
    local ok, err = coroutine.resume(self.coroutine, wrap, ...) -- rev up our coroutine
    -- current_fiber = saved_current_fiber the KEY bit, we only get here when the coroutine above has yielded,
    -- but we then pop back in the fiber we previously displaced
    _current_fiber = saved_current_fiber
    if coroutine.status(self.coroutine) == "dead" then
        self.alive = false
    end
    if not ok then
        -- Report uncaught error to error consumers.
        if #error_waiters > 0 then
            local waiter = table.remove(error_waiters, 1)
            current_scheduler:schedule(setmetatable({
                waiter    = waiter.fiber,
                err_fiber = self,
                err       = err,
            }, WaiterTask))
        else
            error_queue[#error_queue + 1] = {
                fiber = self,
                err   = err,
            }
        end
    end
end

Fiber.run = Fiber.resume

function Fiber:suspend(block_fn, ...)
    assert(_current_fiber == self)
    -- The block_fn should arrange to reschedule the fiber when it
    -- becomes runnable.
    block_fn(current_scheduler, _current_fiber, ...)
    return coroutine.yield()
end

function Fiber:get_traceback()
    return self.traceback or "No traceback available"
end

--- Returns the current Fiber object, or nil if not inside a fiber.
local function current_fiber()
    return _current_fiber
end

local function now()
    return current_scheduler:now()
end

local function suspend(block_fn, ...)
    return _current_fiber:suspend(block_fn, ...)
end

--- Suspends execution of the current fiber.
-- The fiber will be resumed when the scheduler is ready to run it again.
-- @function yield
local function yield()
    return suspend(function(scheduler, fiber)
        scheduler:schedule(fiber)
    end)
end

--- Stops the current scheduler from running more tasks.
-- @function stop
local function stop()
    current_scheduler:stop()
end

local function wait_fiber_error()
    -- Fast path: if an error is already queued, return it immediately.
    if #error_queue > 0 then
        local rec = table.remove(error_queue, 1)
        return rec.fiber, rec.err
    end

    -- Otherwise, we must be in a fibre and suspend until an error arrives.
    assert(_current_fiber, "wait_fiber_error must be called from within a fiber")

    local function block_fn(sched, fib)
        -- Record this fibre as waiting for an error. When an error
        -- arrives, the failing fibre will arrange to schedule a task
        -- that resumes this fibre with (fiber, err).
        error_waiters[#error_waiters + 1] = { fiber = fib }
    end

    local wrap, err_fiber, err = _current_fiber:suspend(block_fn)
    -- wrap should be the identity function; ignore it.
    return err_fiber, err
end


--- Runs the main event loop of the current scheduler.
-- The scheduler will continue to run tasks and wait for events until stopped.
-- @function main
local function main()
    return current_scheduler:main()
end

return {
    -- core runtime state
    current_scheduler = current_scheduler,
    current_fiber     = current_fiber,

    -- time and suspension
    now              = now,
    suspend          = suspend,
    yield            = yield,
    wait_fiber_error = wait_fiber_error,

    -- fiber management
    spawn = spawn,
    stop  = stop,
    main  = main,
}

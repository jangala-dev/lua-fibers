-- fibers/fiber.lua
-- Implements a fiber system using Lua's coroutines for cooperative multitasking.
-- @module fibers.fiber

-- Required packages
local sched = require 'fibers.sched'

local current_fiber
local current_scheduler = sched.new()

--- The Fiber class
-- Represents a single fiber, or lightweight thread.
-- @type Fiber
local Fiber = {}
Fiber.__index = Fiber

-- shared helper
local function _schedule_fiber(fn, scope, tb_level)
    local tb = debug.traceback("", tb_level or 2):match("\n[^\n]*\n(.*)") or ""
    current_scheduler:schedule(setmetatable({
        coroutine = coroutine.create(fn),
        alive = true,
        sockets = {},
        traceback = tb,
        scope = scope, -- the only place we store ambient scope
    }, Fiber))
end

-- Inherit caller's current scope
local function spawn(fn)
    local parent_scope = current_fiber and current_fiber.scope or nil
    _schedule_fiber(fn, parent_scope, 2)
end
--- Resumes execution of the fiber.
-- If the fiber is already dead, this will throw an error.
-- @tparam vararg ... The arguments to pass to the fiber.
function Fiber:resume(wrap, ...)
    assert(self.alive, "dead fiber")
    local saved_current_fiber = current_fiber
    current_fiber = self
    local ok, err = coroutine.resume(self.coroutine, wrap, ...)
    current_fiber = saved_current_fiber
    if not ok then
        print('Error while running fiber: ' .. tostring(err))
        print(debug.traceback(self.coroutine))
        print('fibers history:\n' .. self.traceback)
        os.exit(255)
    end
end

Fiber.run = Fiber.resume

--- Suspends execution of the fiber.
-- The fiber will be resumed when the provided blocking function finishes.
-- @tparam function block_fn The function to block on.
-- @tparam vararg ... The arguments to pass to the blocking function.
function Fiber:suspend(block_fn, ...)
    assert(current_fiber == self)
    -- The block_fn should arrange to reschedule the fiber when it
    -- becomes runnable.
    block_fn(current_scheduler, current_fiber, ...)
    return coroutine.yield()
end

--- Returns the traceback of the fiber.
-- @function get_traceback
function Fiber:get_traceback()
    return self.traceback or "No traceback available"
end

--- Returns the current time according to the current scheduler.
-- @treturn number The current time.
local function now() return current_scheduler:now() end

--- Suspends execution of the current fiber.
-- The fiber will be resumed when the provided blocking function finishes.
-- @function suspend
-- @tparam function block_fn The function to block on.
-- @tparam vararg ... The arguments to pass to the blocking function.
local function suspend(block_fn, ...) return current_fiber:suspend(block_fn, ...) end

local function schedule(scheduler, fiber) scheduler:schedule(fiber) end

--- Suspends execution of the current fiber.
-- The fiber will be resumed when the scheduler is ready to run it again.
-- @function yield
local function yield() return suspend(schedule) end

--- Stops the current scheduler from running more tasks.
-- @function stop
local function stop() current_scheduler:stop() end

--- Runs the main event loop of the current scheduler.
-- The scheduler will continue to run tasks and wait for events until stopped.
-- @function main
local function main() return current_scheduler:main() end

return {
    current_scheduler = current_scheduler,
    spawn = spawn,
    -- For Scope:spawn(): bind a specific scope
    _spawn_with_scope = function(scope, fn) _schedule_fiber(fn, scope, 3) end,
    -- Read-only ambient accessor
    current_scope = function() return current_fiber and current_fiber.scope or nil end,
    now = now,
    suspend = suspend,
    yield = yield,
    stop = stop,
    main = main
}

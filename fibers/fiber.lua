-- (c) Snabb project
-- (c) Jangala

-- Use of this source code is governed by the XXXXXXXXX license; see COPYING.

--- Fiber module.
-- Implements a fiber system using Lua's coroutines for cooperative multitasking.
-- @module fibers.fiber

-- Required packages
local sched = require 'fibers.sched'

local current_fiber
local current_scheduler = sched.new()

local frame_marker = {} -- unique value delimiting stack frames

local function close_frame(stack, e)
   assert(#stack ~= 0, 'Defer stack empty')
   for i=#stack,1,-1 do  -- release in reverse order of acquire
      local v; v, stack[i] = stack[i], nil
      if v == frame_marker then
         break
      else
         v(e)
      end
   end
end

-- Creates a new scope for deferred function calls.
-- A scope is used to group deferred functions that will execute when the scope exits.
-- When the function provided to `defscope` returns, the deferred functions are executed in reverse order.
-- @param fn The main function to execute within the scope.
-- @return A function that represents the scoped execution.
local function defscope(fn)
   local function runner(stack, ...) close_frame(stack); return ... end

   return function(...)
      local stack = current_fiber.defer_stack
      stack[#stack+1] = frame_marker -- new frame
      return runner(stack, fn(...))
   end
end

-- Defers the execution of a function until the surrounding scope exits.
-- Deferred functions are executed in reverse order when the scope exits.
-- @param fn The function to defer.
-- @param ... Optional arguments to pass to the deferred function.
local function defer(fn, ...)
   local args = {...}
   local stack = current_fiber.defer_stack
   stack[#stack+1] = function() fn(unpack(args)) end
 end

 -- Executes a function within a scope and handles deferred functions.
-- Deferred functions are executed in reverse order if an error occurs during execution.
-- @param f The function to execute.
-- @param ... Optional arguments to pass to the function.
-- @return A table with two elements: `ok` (a boolean indicating success) and `...` (the function's return values).
local function fpcall(f, ...)
   local function runner(stack, level, ok, ...)
      local e; if not ok then e = select(1, ...) end
      while #stack > level do close_frame(stack, e) end
      return ...
   end

   local stack = current_fiber.defer_stack
   local level = #stack
   return runner(stack, level, pcall(f, ...))
 end

--- The Fiber class
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
   if current_fiber and current_fiber.traceback then
      tb = tb .. "\n" .. current_fiber.traceback
   end

   current_scheduler:schedule(
      setmetatable({coroutine=coroutine.create(fn),
                    alive=true, sockets={}, traceback=tb, defer_stack={}}, Fiber))
end

--- Resumes execution of the fiber.
-- If the fiber is already dead, this will throw an error.
-- @tparam vararg ... The arguments to pass to the fiber.
function Fiber:resume(...)
   assert(self.alive, "dead fiber") -- checks that the fiber is alive
   local saved_current_fiber = current_fiber -- shift the old current fiber into a safe place
   current_fiber = self -- we are the new current fiber
   local ok, err = coroutine.resume(self.coroutine, ...) -- rev up our coroutine
   current_fiber = saved_current_fiber -- the KEY bit, we only get here when the coroutine above has yielded, but we then pop back in the fiber we previously displaced
   if not ok then
      print('Error while running fiber: '..tostring(err))
      print('executing defer calls:')
      while #self.defer_stack > 0 do close_frame(self.defer_stack) end
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

--- Returns the socket associated with the provided descriptor.
-- @tparam number sd The socket descriptor.
-- @treturn table The socket.
function Fiber:get_socket(sd)
   return assert(self.sockets[sd])
end

--- Adds a new socket to the fiber.
-- @tparam table sock The socket to add.
-- @treturn number The descriptor of the added socket.
function Fiber:add_socket(sock)
   local sd = #self.sockets
   -- FIXME: add refcount on socket
   self.sockets[sd] = sock
   return sd
end

--- Closes the socket associated with the provided descriptor.
-- @tparam number sd The socket descriptor.
function Fiber:close_socket(sd)
   local s = self:get_socket(sd)
   self.sockets[sd] = nil
   -- FIXME: remove refcount on socket
end

--- Waits until the socket associated with the provided descriptor is readable.
-- @tparam number sd The socket descriptor.
function Fiber:wait_for_readable(sd)
   local s = self:get_socket(sd)
   current_scheduler:resume_when_readable(s, self)
   return coroutine.yield()
end

--- Waits until the socket associated with the provided descriptor is writable.
-- @tparam number sd The socket descriptor.
function Fiber:wait_for_writable(sd)
   local s = self:get_socket(sd)
   current_scheduler:schedule_when_writable(s, self)
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

local function schedule(sched, fiber) sched:schedule(fiber) end

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
   now = now,
   suspend = suspend,
   yield = yield,
   stop = stop,
   main = main,
   defscope = defscope,
   defer = defer,
   fpcall = fpcall
}
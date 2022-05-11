-- (c) Snabb project
-- (c) Jangala

-- Use of this source code is governed by the XXXXXXXXX license; see COPYING.

-- Fibers.

package.path = "../?.lua;" .. package.path

local sched = require 'fibers.sched'

local current_fiber = false
local current_scheduler = sched.new()

local Fiber = {}
Fiber.__index = Fiber

--- Creates a new fiber. A fiber is simply a table, containing a coroutine
--- and some status and wait parameters
-- @param fn function to run in the fiber
local function spawn(fn)
   current_scheduler:schedule(
      setmetatable({coroutine=coroutine.create(fn),
                    alive=true, sockets={}}, Fiber))
end

--- Resuming a fiber runs the coroutine.
-- @param ... parameters passed to the coroutine
function Fiber:resume(...)
   assert(self.alive, "dead fiber") -- checks that the fiber is alive
   local saved_current_fiber = current_fiber -- shift the old current fiber into a safe place
   current_fiber = self -- we are the new current fiber
   local ok, err = coroutine.resume(self.coroutine, ...) -- rev up our coroutine
   current_fiber = saved_current_fiber -- the KEY bit, we only get here when the coroutine above has yielded, but we then pop back in the fiber we previously displaced
   if not ok then
      print('Error while running fiber: '..tostring(err))
      self.alive = false
   end
end
Fiber.run = Fiber.resume

--- Suspending a fiber suspends the coroutine.
-- @param block_fn The block function should arrange to reschedule
-- the fiber when it becomes runnable
function Fiber:suspend(block_fn, ...)
   assert(current_fiber == self)
   -- The block_fn should arrange to reschedule the fiber when it
   -- becomes runnable.
   block_fn(current_scheduler, current_fiber, ...)
   return coroutine.yield()
end

function Fiber:get_socket(sd)
   return assert(self.sockets[sd])
end

function Fiber:add_socket(sock)
   local sd = #self.sockets
   -- FIXME: add refcount on socket
   self.sockets[sd] = sock
   return sd
end

function Fiber:close_socket(sd)
   local s = self:get_socket(sd)
   self.sockets[sd] = nil
   -- FIXME: remove refcount on socket
end

function Fiber:wait_for_readable(sd)
   local s = self:get_socket(sd)
   current_scheduler:resume_when_readable(s, self)
   return coroutine.yield()
end

function Fiber:wait_for_writable(sd)
   local s = self:get_socket(sd)
   current_scheduler:schedule_when_writable(s, self)
   return coroutine.yield()
end

local function now() return current_scheduler:now() end
---@diagnostic disable-next-line: need-check-nil
local function suspend(block_fn, ...) return current_fiber:suspend(block_fn, ...) end

local function schedule(sched, fiber) sched:schedule(fiber) end
local function yield() return suspend(schedule) end

local function stop() current_scheduler:stop() end
local function main() return current_scheduler:main() end

local function selftest()
   print('selftest: fibers.fiber')
   local equal = require 'fibers.utils.helper'.equal
   local log = {}
   local function record(x) table.insert(log, x) end

   spawn(function()
      record('a'); yield(); record('b'); yield(); record('c')
   end)

   assert(equal(log, {}))
   current_scheduler:run()
   assert(equal(log, {'a'}))
   current_scheduler:run()
   assert(equal(log, {'a', 'b'}))
   current_scheduler:run()
   assert(equal(log, {'a', 'b', 'c'}))
   current_scheduler:run()
   assert(equal(log, {'a', 'b', 'c'}))

   print('selftest: ok')
end

return {
   current_scheduler = current_scheduler,
   spawn = spawn,
   now = now,
   suspend = suspend,
   yield = yield,
   stop = stop,
   main = main,
   selftest = selftest
}
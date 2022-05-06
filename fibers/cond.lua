-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

-- Cond implements a condition variable, a rendezvous point for
-- fibers waiting for or announcing the occurrence of an event. This is very
-- much like go's Cond type, BUT the method signal here is equivalent to
-- Cond's `Broadcast`

package.path = "../?.lua;" .. package.path

local op = require('fibers.op')

local Cond = {}

local function new()
   return setmetatable({ waitq={} }, {__index=Cond})
end

-- Make an operation that will complete when and if the condition is
-- signalled.
function Cond:wait_operation()
   local function try() return not self.waitq end
   local function gc()
      local i = 1
      while i <= #self.waitq do
         if self.waitq[i].suspension:waiting() then
            i = i + 1
         else
            table.remove(self.waitq, i)
         end
      end
   end
   local function block(suspension, wrap_fn)
      gc()
      table.insert(self.waitq, {suspension=suspension, wrap=wrap_fn})
   end
   return op.new_base_op(nil, try, block)
end

function Cond:wait() return self:wait_operation():perform() end

function Cond:signal()
   if self.waitq ~= nil then
      for _,remote in ipairs(self.waitq) do
         if remote.suspension:waiting() then
            remote.suspension:complete(remote.wrap)
         end
      end
      self.waitq = nil
   end
end

local function selftest()
   print('selftest: lib.fibers.cond')
   local equal = require 'fibers.utils.helper'.equal
   local fiber = require('fibers.fiber')
   local cond, log = new(), {}
   local function record(x) table.insert(log, x) end

   fiber.spawn(function() record('a'); cond:wait(); record('b') end)
   fiber.spawn(function() record('c'); cond:signal(); record('d') end)
   assert(equal(log, {}))
   fiber.current_scheduler:run()
   assert(equal(log, {'a', 'c', 'd'}))
   fiber.current_scheduler:run()
   assert(equal(log, {'a', 'c', 'd', 'b'}))

   print('selftest: ok')
end

return {
   new = new,
   selftest = selftest
}
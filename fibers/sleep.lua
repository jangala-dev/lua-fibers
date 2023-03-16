-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

-- Timeout events.
package.path = "../?.lua;" .. package.path

local op = require('fibers.op')
local fiber = require('fibers.fiber')
local now = fiber.now

local Timeout = {}
Timeout.__index = Timeout

--- Creates a new operation that will sleep until a specific monotonic time.
local function sleep_until_op(t)
   local function try()
      return t <= now()
   end
   local function block(suspension, wrap_fn)
      suspension.sched:schedule_at_time(t, suspension:complete_task(wrap_fn))
   end
   return op.new_base_op(nil, try, block)
end

--- Sleeps until a specific monotonic time.
local function sleep_until(t)
   return sleep_until_op(t):perform()
end

--- Creates a new operation that will sleep for a specific number of seconds.
local function sleep_op(dt)
   local function try() return dt <= 0 end
   local function block(suspension, wrap_fn)
      suspension.sched:schedule_after_sleep(dt, suspension:complete_task(wrap_fn))
   end
   return op.new_base_op(nil, try, block)
end

--- Sleeps for a specific number of seconds.
local function sleep(dt)
   return sleep_op(dt):perform()
end

local function selftest()
   print('selftest: lib.fibers.sleep')
   local done = {}
   local count = 1e3
   for i=1,count do
      local function fn()
         local start, dt = now(), math.random()
         sleep(dt)
         assert(now() >= start + dt)
         table.insert(done, i)
      end
      fiber.spawn(fn)
   end
   for t=now(),now()+1.5,0.01 do
      fiber.current_scheduler:run(t)
   end
   assert(#done == count)
   print('selftest: ok')
end

return {
   sleep = sleep,
   sleep_op = sleep_op,
   sleep_until = sleep_until,
   sleep_until_op = sleep_until_op,
   selftest = selftest,
}
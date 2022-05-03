-- (c) Snabb project
-- (c) Jangala

-- Use of this source code is governed by the XXXXXXXXX license; see COPYING.

-- Fibers.
package.path = "../?.lua;" .. package.path

local syscall = require 'fibers.utils.syscall'
local timer = require 'fibers.timer'

local MAX_SLEEP_TIME = 10

local Scheduler = {}

-- when a new scheduler is created a new timer wheel is created for it
local function new()
   ret = setmetatable(
      { next={}, cur={}, sources={}, wheel=timer.new_timer_wheel() },
      {__index=Scheduler})
   local timer_task_source = { wheel=ret.wheel }
   -- private method for timer_tast_source
   function timer_task_source:schedule_tasks(sched, now)
      self.wheel:advance(now, sched)
   end
   -- private method for timer_tast_source
   function timer_task_source:cancel_all_tasks(sched)
      -- Implement me!
   end
   ret:add_task_source(timer_task_source)
   return ret
end

function Scheduler:add_task_source(source)
   table.insert(self.sources, source)
   if source.wait_for_events then self.event_waiter = source end
end

--- Adds a task to be scheduled on the scheduler.
-- @param task task to be scheduled next on the scheduler
function Scheduler:schedule(task)
   table.insert(self.next, task)
end

--- Returns the current time of the scheduler.
-- @return current time of the scheduler
function Scheduler:now()
   return self.wheel.now
end

--- Adds a task to be scheduled to run at a later absolute time.
-- @param t absolute time at which task is to be run
-- @param task task to be scheduled next on the scheduler
function Scheduler:schedule_at_time(t, task)
   self.wheel:add_absolute(t, task)
end

--- Adds a task to be scheduled to run after a relative time.
-- @param dt elapsed time after which the task is to be run
-- @param task task to be scheduled next on the scheduler
function Scheduler:schedule_after_sleep(dt, task)
   self.wheel:add_delta(dt, task)
end

function Scheduler:schedule_tasks_from_sources(now)
   for i=1,#self.sources do
      self.sources[i]:schedule_tasks(self, now)
   end
end

function Scheduler:run(now)
   if now == nil then now = self:now() end
   self:schedule_tasks_from_sources(now)
   self.cur, self.next = self.next, self.cur
   for i=1,#self.cur do
      local task = self.cur[i]
      self.cur[i] = nil
      task:run()
   end
end

--- Returns the next wake time for the scheduler.
-- @return the time at which the scheduler will wake next
function Scheduler:next_wake_time()
   if #self.next > 0 then return self:now() end
   return self.wheel:next_entry_time()
end

--- Allows the system to sleep until the next task is scheduled in the scheduler.
function Scheduler:wait_for_events()
   local now, next_time = syscall.monotonic_float() , self:next_wake_time()
   local timeout = math.min(MAX_SLEEP_TIME, next_time - now)
   if self.event_waiter then
      self.event_waiter:wait_for_events(self, now, timeout)
   else
      syscall.sleep_float(timeout)
   end
end

--- Method stops the scheduler.
function Scheduler:stop()
   self.done = true
end

--- Method starts the scheduler.
function Scheduler:main()
   self.done = false
   repeat
      self:wait_for_events()
      self:run(syscall.monotonic_float())
   until self.done
end

--- Method cancels tasks and  shuts down the scheduler.
function Scheduler:shutdown()
   for i=1,100 do
      for i=1,#self.sources do self.sources[i]:cancel_all_tasks(self) end
      if #self.next == 0 then return true end
      self:run()
   end
   return false
end

function selftest ()
   print("selftest: lib.fibers.scheduler")
   local scheduler = new()

   local last, count = 0, 0
   local function task_run(task)
      local now = scheduler:now()
      local t = task.scheduled
      last, count = t, count + 1
      -- Check that tasks run within a tenth a tick of when they should.
      -- Floating-point imprecisions can cause either slightly early or
      -- slightly late ticks.
      assert(scheduler:now() - scheduler.wheel.period*1.1 < t)
      assert(t < scheduler:now() + scheduler.wheel.period*0.1)
   end

   local event_count = 1e5
   local t = scheduler:now()
   for i=1,event_count do
      local dt = math.random()
      t = t + dt
      scheduler:schedule_at_time(t, {run=task_run, scheduled=t})
   end
   
   for now=scheduler:now(),t+1,scheduler.wheel.period do
      scheduler:run(now)
   end

   assert(count == event_count)

   print("selftest: ok")
end

return {
   new = new,
   selftest = selftest
}
-- fibers/sched.lua
--
-- Cooperative, single-threaded FIFO scheduler with idempotent enqueue.

local Scheduler = {}
Scheduler.__index = Scheduler

function Scheduler.new()
  return setmetatable({ q = {}, head = 1, tail = 0 }, Scheduler)
end

-- Scheduler:schedule is intentionally idempotent.
function Scheduler:schedule(task)
  if task._queued then return end
  task._queued = true
  self.tail = self.tail + 1
  self.q[self.tail] = task
end

-- Scheduler:step runs exactly one task from the FIFO queue.
function Scheduler:step()
  if self.head > self.tail then
    return false
  end

  local t = self.q[self.head]
  self.q[self.head] = nil
  self.head = self.head + 1

  t._queued = false
  t:run(self)

  if self.head > self.tail then
    self.head, self.tail = 1, 0
  end
  return true
end

return {
  Scheduler = Scheduler,
  new = Scheduler.new,
}

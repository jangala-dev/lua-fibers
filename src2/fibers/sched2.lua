-- fibers/sched2.lua
--
-- Minimal cooperative scheduler.
--
-- Purpose
--   Provides a run-queue for Tasks in a single-threaded, non-preemptive runtime.
--   The scheduler does not understand blocking. It only executes runnable work.
--
-- Task contract
--   * A Task is any table with: task:run(sched).
--   * Scheduling is idempotent: schedule(task) is a no-op if task._queued is true.
--   * step() runs at most one queued task and returns true if it ran something.
--   * If no task is runnable, step() returns false.
--
-- Invariants
--   * The scheduler never pre-empts: a task runs until it returns from :run().
--   * The scheduler makes no assumptions about tasks other than :run().
--   * Blocking/waiting must be expressed outside the scheduler (via pulses + fibres).
--
-- API
--   * Scheduler.new() -> scheduler
--   * scheduler:schedule(task)
--   * scheduler:step() -> boolean
--   * scheduler:run()

local Scheduler = {}
Scheduler.__index = Scheduler

function Scheduler.new()
	return setmetatable({
		q    = {},
		head = 1,
		tail = 0,
	}, Scheduler)
end

function Scheduler:schedule(task)
	if task._queued then return end
	task._queued = true

	self.tail = self.tail + 1
	self.q[self.tail] = task
end

-- Run exactly one runnable task. Returns true if something ran.
function Scheduler:step()
	if self.head > self.tail then
		return false
	end

	local t = self.q[self.head]
	self.q[self.head] = nil
	self.head = self.head + 1

	t._queued = false
	t:run(self)

	-- Compact the queue when empty, to avoid head/tail growing unbounded.
	if self.head > self.tail then
		self.head = 1
		self.tail = 0
	end

	return true
end

function Scheduler:run()
	while self:step() do end
end

return {
	new = Scheduler.new,
}

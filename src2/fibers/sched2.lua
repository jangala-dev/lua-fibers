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

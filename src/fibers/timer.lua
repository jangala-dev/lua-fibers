-- fibers/timer.lua

--- Monotonic timer built on a binary min-heap.
---@module 'fibers.timer'

---@class TimerNode
---@field time number  # absolute due time (monotonic seconds)
---@field obj any     # scheduled payload

--- Simple min-heap keyed by node.time.
---@class Heap
---@field heap TimerNode[]
---@field size integer
local Heap = {}
Heap.__index = Heap

---@return Heap
local function new_heap()
    return setmetatable({ heap = {}, size = 0 }, Heap)
end

---@param node TimerNode
function Heap:push(node)
    self.size = self.size + 1
    self.heap[self.size] = node
    self:heapify_up(self.size)
end

---@return TimerNode|nil
function Heap:pop()
    if self.size == 0 then
        return nil
    end

    local root = self.heap[1]
    if self.size == 1 then
        self.heap[1] = nil
        self.size    = 0
        return root
    end

    self.heap[1]         = self.heap[self.size]
    self.heap[self.size] = nil
    self.size            = self.size - 1
    self:heapify_down(1)
    return root
end

---@param idx integer
function Heap:heapify_up(idx)
    if idx <= 1 then return end
    local parent = math.floor(idx / 2)
    if self.heap[parent].time > self.heap[idx].time then
        self.heap[parent], self.heap[idx] = self.heap[idx], self.heap[parent]
        self:heapify_up(parent)
    end
end

---@param idx integer
function Heap:heapify_down(idx)
    local smallest = idx
    local left     = 2 * idx
    local right    = 2 * idx + 1

    if left <= self.size and self.heap[left].time < self.heap[smallest].time then
        smallest = left
    end
    if right <= self.size and self.heap[right].time < self.heap[smallest].time then
        smallest = right
    end
    if smallest ~= idx then
        self.heap[idx], self.heap[smallest] = self.heap[smallest], self.heap[idx]
        self:heapify_down(smallest)
    end
end

---@class Scheduler
---@field schedule fun(self: Scheduler, obj: any)  # called when a timer fires

--- Monotonic timer used by the scheduler.
---@class Timer
---@field now number  # current timer time (monotonic seconds)
---@field heap Heap
local Timer = {}
Timer.__index = Timer

--- Create a new timer instance.
---@param now? number # initial monotonic time.
---@return Timer
local function new(now)
    assert(now)
    return setmetatable({ now = now, heap = new_heap() }, Timer)
end

--- Schedule an object at absolute time t.
---@param t number   # absolute due time (same clock as sc.monotime)
---@param obj any    # payload to pass to the scheduler
function Timer:add_absolute(t, obj)
    self.heap:push({ time = t, obj = obj })
end

--- Schedule an object after a delay from the current timer time.
---@param dt number  # delay in seconds from self.now
---@param obj any    # payload to pass to the scheduler
function Timer:add_delta(dt, obj)
    return self:add_absolute(self.now + dt, obj)
end

--- Get the time of the next scheduled entry, or math.huge if none exist.
--- This is the only method used by the scheduler to determine wake-up time.
---@return number
function Timer:next_entry_time()
    if self.heap.size == 0 then
        return math.huge
    end
    return self.heap.heap[1].time
end

--- Pop the next scheduled entry without dispatching it.
--- Returns the earliest TimerNode or nil if the timer is empty.
---@return TimerNode|nil
function Timer:pop()
    return self.heap:pop()
end

--- Advance the timer to time t and dispatch all due entries.
--- For each entry with time <= t, sched:schedule(node.obj) is invoked.
---@param t number       # new monotonic time
---@param sched Scheduler # scheduler that receives due objects
function Timer:advance(t, sched)
    while self.heap.size > 0 and t >= self.heap.heap[1].time do
        local node = assert(self.heap:pop())
        self.now   = node.time
        sched:schedule(node.obj)
    end
    self.now = t
end

return {
    new = new,
}

-- fibers/timer.lua

--- Monotonic timer built on a binary min-heap.
---@module 'fibers.timer'

---@class TimerNode
---@field time number  # absolute due time (monotonic seconds)
---@field obj any     # scheduled payload

local floor, huge = math.floor, math.huge

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
    local size = self.size + 1
    self.size = size
    self.heap[size] = node
    self:heapify_up(size)
end

---@return TimerNode|nil
function Heap:pop()
    local size = self.size
    if size == 0 then
        return nil
    end

    local heap = self.heap
    local root = heap[1]

    if size == 1 then
        heap[1] = nil
        self.size = 0
        return root
    end

    heap[1] = heap[size]
    heap[size] = nil
    self.size = size - 1
    self:heapify_down(1)

    return root
end

---@param idx integer
function Heap:heapify_up(idx)
    local heap = self.heap
    while idx > 1 do
        local parent = floor(idx / 2)
        if heap[parent].time <= heap[idx].time then
            break
        end
        heap[parent], heap[idx] = heap[idx], heap[parent]
        idx = parent
    end
end

---@param idx integer
function Heap:heapify_down(idx)
    local heap  = self.heap
    local size  = self.size

    while true do
        local left  = 2 * idx
        local right = left + 1
        local smallest = idx

        if left <= size and heap[left].time < heap[smallest].time then
            smallest = left
        end
        if right <= size and heap[right].time < heap[smallest].time then
            smallest = right
        end

        if smallest == idx then
            break
        end

        heap[idx], heap[smallest] = heap[smallest], heap[idx]
        idx = smallest
    end
end

---@class Timer
---@field now number  # current timer time (monotonic seconds)
---@field heap Heap
local Timer = {}
Timer.__index = Timer

--- Create a new timer instance.
---@param now number # initial monotonic time.
---@return Timer
local function new(now)
    return setmetatable({ now = now, heap = new_heap() }, Timer)
end

--- Schedule an object at absolute time t.
---@param t number   # absolute due time
---@param obj any    # payload to pass to the scheduler
function Timer:add_absolute(t, obj)
    self.heap:push { time = t, obj = obj }
end

--- Schedule an object after a delay from the current timer time.
---@param dt number  # delay in seconds from self.now
---@param obj any    # payload to pass to the scheduler
function Timer:add_delta(dt, obj)
    self:add_absolute(self.now + dt, obj)
end

--- Get the time of the next scheduled entry, or math.huge if none exist.
---@return number
function Timer:next_entry_time()
    local heap = self.heap
    return heap.size > 0 and heap.heap[1].time or huge
end

--- Pop the next scheduled entry without dispatching it.
---@return TimerNode|nil
function Timer:pop()
    return self.heap:pop()
end

--- Advance the timer to time t and dispatch all due entries.
---@param t number        # new monotonic time
---@param sched { schedule: fun(self:any, obj:any) }
function Timer:advance(t, sched)
    local heap = self.heap

    while heap.size > 0 and t >= heap.heap[1].time do
        local node = assert(heap:pop()) -- non-nil since size>0
        self.now = node.time
        sched:schedule(node.obj)
    end

    self.now = t
end

return { new = new }

-- (c) Jangala
--
-- Use of this source code is governed by the XXXXXXXXX license; see COPYING.

--- Binary-heap timer.
-- @module fibers.timer

local sc = require 'fibers.utils.syscall'

--- Simple min-heap keyed by node.time.
local BinaryHeap = {}
BinaryHeap.__index = BinaryHeap

function BinaryHeap:new()
    return setmetatable({ heap = {}, size = 0 }, BinaryHeap)
end

function BinaryHeap:push(node)
    self.size = self.size + 1
    self.heap[self.size] = node
    self:heapify_up(self.size)
end

function BinaryHeap:pop()
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

function BinaryHeap:heapify_up(idx)
    if idx <= 1 then return end
    local parent = math.floor(idx / 2)
    if self.heap[parent].time > self.heap[idx].time then
        self.heap[parent], self.heap[idx] = self.heap[idx], self.heap[parent]
        self:heapify_up(parent)
    end
end

function BinaryHeap:heapify_down(idx)
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

--- Timer built on top of BinaryHeap.
local Timer = {}
Timer.__index = Timer

--- Create a new timer.
-- @tparam[opt] number now initial time (defaults to sc.monotime()).
local function new(now)
    now = now or sc.monotime()
    return setmetatable({ now = now, heap = BinaryHeap:new() }, Timer)
end

--- Schedule at absolute time t.
function Timer:add_absolute(t, obj)
    self.heap:push({ time = t, obj = obj })
end

--- Schedule after delay dt from current timer time.
function Timer:add_delta(dt, obj)
    return self:add_absolute(self.now + dt, obj)
end

--- Time of next entry, or math.huge if none.
-- This is the only API relied on by the scheduler.
function Timer:next_entry_time()
    if self.heap.size == 0 then
        return math.huge
    end
    return self.heap.heap[1].time
end

--- Low-level pop of the next node.
-- Returns { time = ..., obj = ... } or nil.
-- Not used by the scheduler; kept for possible callers that want manual control.
function Timer:pop()
    return self.heap:pop()
end

--- Advance to time t, scheduling all entries <= t on sched.
function Timer:advance(t, sched)
    while self.heap.size > 0 and t >= self.heap.heap[1].time do
        local node = self.heap:pop()
        self.now   = node.time
        sched:schedule(node.obj)
    end
    self.now = t
end

return {
    new = new
}

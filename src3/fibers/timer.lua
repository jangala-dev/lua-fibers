-- fibers/timer.lua
--
-- Monotonic timer queue (min-heap) that signals Pulses when due.
-- Supports lazy cancellation (idempotent cancel handles).

local floor, huge = math.floor, math.huge

---@class TimerNode
---@field time number
---@field waker any    -- Pulse-like object with :signal()
---@field cancelled boolean

---@class Heap
---@field heap TimerNode[]
---@field size integer
local Heap = {}
Heap.__index = Heap

local function new_heap()
  return setmetatable({ heap = {}, size = 0 }, Heap)
end

function Heap:push(node)
  local size = self.size + 1
  self.size = size
  self.heap[size] = node
  self:heapify_up(size)
end

function Heap:pop()
  local size = self.size
  if size == 0 then return nil end

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

function Heap:heapify_up(idx)
  local heap = self.heap
  while idx > 1 do
    local parent = floor(idx / 2)
    if heap[parent].time <= heap[idx].time then break end
    heap[parent], heap[idx] = heap[idx], heap[parent]
    idx = parent
  end
end

function Heap:heapify_down(idx)
  local heap = self.heap
  local size = self.size

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

    if smallest == idx then break end
    heap[idx], heap[smallest] = heap[smallest], heap[idx]
    idx = smallest
  end
end

---@class Timer
---@field now number
---@field heap Heap
local Timer = {}
Timer.__index = Timer

local function new(now)
  return setmetatable({ now = now, heap = new_heap() }, Timer)
end

--- Schedule a Pulse to be signalled at absolute time t.
---@param t number
---@param waker any
---@return TimerNode handle
function Timer:add_absolute(t, waker)
  local node = { time = t, waker = waker, cancelled = false }
  self.heap:push(node)
  return node
end

function Timer:add_delta(dt, waker)
  return self:add_absolute(self.now + dt, waker)
end

--- Cancel a scheduled handle (idempotent).
---@param handle TimerNode|nil
function Timer:cancel(handle)
  if handle then
    handle.cancelled = true
    handle.waker = nil
  end
end

function Timer:_prune_top()
  local heap = self.heap
  while heap.size > 0 do
    local top = heap.heap[1]
    if not top.cancelled then return end
    heap:pop()
  end
end

--- Next deadline time, or math.huge if none.
function Timer:next_entry_time()
  self:_prune_top()
  local heap = self.heap
  return heap.size > 0 and heap.heap[1].time or huge
end

--- Advance to time t and signal all due Pulses.
---@param t number
function Timer:advance(t)
  local heap = self.heap

  while true do
    self:_prune_top()
    if heap.size == 0 then break end

    local top = heap.heap[1]
    if t < top.time then break end

    local node = heap:pop()
    self.now = node.time

    local w = node.waker
    if (not node.cancelled) and w then
      w:signal()
    end
  end

  self.now = t
end

return {
  Timer = Timer,
  new   = new,
}

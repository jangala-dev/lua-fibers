local Op = require('fibers.op')
local Index = require('fibers.resource.index')
local Counter = require('fibers.resource.counter')
local perform = require('fibers.perform')

local PriorityQueue = {}
PriorityQueue.__index = PriorityQueue

local function child_name(name, suffix)
  return name and name .. ':' .. suffix or nil
end

local function create(name)
  return setmetatable({ _items = Index.new(child_name(name, 'items')) }, PriorityQueue)
end

function PriorityQueue.new(capacity, name)
  assert(
    capacity == math.huge
      or type(capacity) == 'number' and capacity >= 0 and capacity % 1 == 0,
    'priority queue capacity must be a non-negative integer or math.huge'
  )

  local queue = create(name)
  if capacity ~= math.huge then
    queue._slots = Counter.bounded(capacity, child_name(name, 'slots'))
  end
  return queue
end

function PriorityQueue:put_op(priority, value)
  local put = self._items:insert_auto_op(priority, value)
  if not self._slots then return put end
  return Op.together({ self._slots:take_op(), put }):map(function()
    return true
  end)
end

function PriorityQueue:get_op()
  local get = self._items:pop_first_op()
  if not self._slots then
    return get:map(function(entry) return entry.value, entry.rank end)
  end
  return get:and_then(Op.guard(function(entry)
    return self._slots:give_op():map(function()
      return entry.value, entry.rank
    end)
  end))
end

function PriorityQueue:put(priority, value)
  return perform(self:put_op(priority, value))
end

function PriorityQueue:get()
  return perform(self:get_op())
end

return PriorityQueue

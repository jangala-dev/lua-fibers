local Op = require('fibers.op')
local Index = require('fibers.resource.index')
local Counter = require('fibers.resource.counter')
local perform = require('fibers.perform')

local PriorityQueue = {}
PriorityQueue.__index = PriorityQueue

local function child_label(label, suffix)
  return label and label .. ':' .. suffix or nil
end

local function create()
  return setmetatable({ _items = Index.new() }, PriorityQueue)
end

function PriorityQueue.new(capacity)
  assert(
    capacity == math.huge
      or type(capacity) == 'number' and capacity >= 0 and capacity % 1 == 0,
    'priority queue capacity must be a non-negative integer or math.huge'
  )

  local queue = create()
  if capacity ~= math.huge then
    queue._slots = Counter.bounded(capacity)
  end
  return queue
end

function PriorityQueue:label(...)
  if select('#', ...) == 0 then return self._label end
  local value = select(1, ...)
  if value ~= nil and (type(value) ~= 'string' or value == '') then
    error('PriorityQueue:label expects a non-empty string or nil', 2)
  end
  self._label = value
  self._items:label(child_label(value, 'items'))
  if self._slots then self._slots:label(child_label(value, 'slots')) end
  return self
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

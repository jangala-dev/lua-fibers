-- Transactional priority queue built from Index + Counter.
-- Lower numeric priority/rank is returned first.  Equal priorities are ordered
-- by the Index auto-insert sequence.

local Op = require('fibers.atoms.op')
local Index = require('fibers.atoms.index')
local Counter = require('fibers.atoms.counter')

local PriorityQueue = {}
PriorityQueue.__index = PriorityQueue
local next_id = 0

function PriorityQueue.new(opts, name)
  opts = opts or {}
  if type(opts) == 'number' then
    opts = { capacity = opts }
  end
  next_id = next_id + 1
  local id = 'priority-queue-' .. tostring(next_id)
  local qname = opts.name or name or id
  local cap = opts.capacity
  return setmetatable({
    name = qname,
    items = opts.items or Index.new({}, qname .. ':items'),
    slots = cap and Counter.new({ initial = cap, min = 0, max = cap, name = qname .. ':slots' })
      or nil,
    capacity = cap,
  }, PriorityQueue)
end

function PriorityQueue:put_op(priority, value)
  if priority == nil then
    error('priority queue put requires a priority', 2)
  end
  local put_item = self.items:insert_auto_op(priority, value)
  if not self.slots then
    return put_item
  end
  return Op.tensor({ self.slots:take_op(1), put_item }):map(function()
    return true
  end)
end

function PriorityQueue:get_op()
  return self.items:pop_first_op():and_then(function(entry)
    local release = self.slots and self.slots:give_op(1) or Op.always(true)
    return release:map(function()
      return entry.value, entry.rank
    end)
  end)
end

function PriorityQueue:snapshot_op()
  return self.items:snapshot_op():map(function(snapshot)
    local rows = {}
    for _, e in pairs(snapshot.entries or {}) do
      rows[#rows + 1] = { key = e.key, priority = e.rank, value = e.value, seq = e.seq }
    end
    table.sort(rows, function(a, b)
      if a.priority == b.priority then
        return (a.seq or 0) < (b.seq or 0)
      end
      return a.priority < b.priority
    end)
    return rows
  end)
end

return PriorityQueue

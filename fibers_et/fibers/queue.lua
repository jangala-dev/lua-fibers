-- Transactional FIFO queue built from Index + Counter.
--
-- Queue is intentionally ordinary Lua code over base primitives.  Index handles
-- ordered selection premises; Counter handles bounded capacity/free slots.

local Op = require('fibers.atoms.op')
local Index = require('fibers.atoms.index')
local Counter = require('fibers.atoms.counter')

local Queue = {}
Queue.__index = Queue

local next_id = 0

function Queue.new(opts, name)
  opts = opts or {}
  if type(opts) == 'number' then opts = { capacity = opts } end
  next_id = next_id + 1
  local id = 'queue-' .. tostring(next_id)
  local qname = opts.name or name or id
  local capacity = opts.capacity
  local self = setmetatable({
    name = qname,
    items = opts.items or Index.new({}, qname .. ':items'),
    slots = capacity and Counter.new({ initial = capacity, min = 0, max = capacity, name = qname .. ':slots' }) or nil,
    capacity = capacity,
  }, Queue)
  return self
end

function Queue:put_op(value)
  local put_item = self.items:append_op(value)
  if not self.slots then return put_item end
  return Op.tensor({ self.slots:take_op(1), put_item }):map(function() return true end)
end

function Queue:get_op()
  return self.items:pop_first_op():and_then(function(entry)
    local release = self.slots and self.slots:give_op(1) or Op.always(true)
    return release:map(function() return entry.value end)
  end)
end

function Queue:snapshot_op()
  return self.items:snapshot_op():map(function(snapshot)
    local rows = {}
    for _, e in pairs(snapshot.entries or {}) do rows[#rows + 1] = { key = e.key, rank = e.rank, value = e.value, seq = e.seq } end
    table.sort(rows, function(a, b)
      if a.rank == b.rank then return tostring(a.key) < tostring(b.key) end
      return a.rank < b.rank
    end)
    return rows
  end)
end

return Queue

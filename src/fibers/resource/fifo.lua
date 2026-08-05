-- Transactional FIFO built from Index + Counter.

local Op = require('fibers.op')
local Index = require('fibers.resource.index')
local Counter = require('fibers.resource.counter')
local Direct = require('fibers.internal.direct')
local Facility = require('fibers.resource.authoring')
local Label = require('fibers.internal.label')

local FIFO = {}
FIFO.__index = FIFO
local Kind = Facility.kind('fifo')

local function return_true()
  return true
end

local function entry_value(entry)
  return entry.value
end

local function validate_capacity(capacity)
  if type(capacity) ~= 'number'
    or capacity < 0
    or capacity ~= capacity
    or (capacity ~= math.huge and capacity % 1 ~= 0)
  then
    error('fifo capacity must be a non-negative integer or math.huge', 3)
  end
end

function FIFO.new(capacity)
  validate_capacity(capacity)

  local items = Index.new()
  local fifo = Facility.identity(setmetatable({
    capacity = capacity,
    _items = items,
  }, FIFO), Kind)

  Label.child(items, fifo, 'items')
  local take_item = items:pop_first_op()

  if capacity == math.huge then
    fifo._get_op = take_item:map(entry_value)
    return fifo
  end

  local slots = Counter.bounded(capacity)

  Label.child(slots, fifo, 'slots')
  local take_slot = slots:take_op()
  local give_slot = slots:give_op()

  fifo._slots = slots
  fifo._take_slot_op = take_slot

  -- The outer operation is immutable and can be reused. The guard residual
  -- remains request-local because it depends on the provisional entry.
  fifo._get_op = take_item:and_then(Op.guard(function(entry)
    return give_slot:map(function()
      return entry.value
    end)
  end))

  return fifo
end

function FIFO:put_op(item)
  local append = self._items:append_op(item)

  if self._take_slot_op == nil then
    return append
  end

  -- Passing fixed lanes directly avoids constructing and validating an
  -- intermediate array.
  return Op.together(
    self._take_slot_op,
    append
  ):map(return_true)
end

function FIFO:get_op()
  return self._get_op
end

Direct.install(FIFO, { 'put', 'get' })

return FIFO
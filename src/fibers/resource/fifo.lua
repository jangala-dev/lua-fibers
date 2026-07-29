-- Transactional FIFO built from Index + Counter.

local Op = require('fibers.op')
local Index = require('fibers.resource.index')
local Counter = require('fibers.resource.counter')
local perform = require('fibers.perform')

local FIFO = {}
FIFO.__index = FIFO

local function truth()
  return true
end

local function value(entry)
  return entry.value
end

local function create(name)
  return setmetatable({
    _items = Index.new(name and name .. ':items'),
  }, FIFO)
end

local function finish(fifo)
  fifo._put_footprint = Op.dependencies(fifo._items:append_footprint(), fifo._slots and fifo._slots:take_op())
  fifo._get_footprint = Op.dependencies(fifo._items:pop_first_op(), fifo._slots and fifo._slots:give_op())
  return fifo
end

function FIFO.new(capacity, name)
  if
    type(capacity) ~= 'number'
    or capacity < 0
    or capacity ~= capacity
    or (capacity ~= math.huge and capacity % 1 ~= 0)
  then
    error('fifo capacity must be a non-negative integer or math.huge', 2)
  end

  local fifo = create(name)
  fifo.capacity = capacity

  if capacity ~= math.huge then
    fifo._slots = Counter.bounded(capacity, name and name .. ':slots')
  end

  return finish(fifo)
end

function FIFO:put_footprint()
  return self._put_footprint
end

function FIFO:get_footprint()
  return self._get_footprint
end

function FIFO:put_op(item)
  local put = self._items:append_op(item)
  if not self._slots then
    return put
  end
  return Op.together({ self._slots:take_op(), put }):map(truth)
end

function FIFO:get_op()
  local get = self._items:pop_first_op()
  if not self._slots then
    return get:map(value)
  end

  return get:and_then(function(entry)
    return self._slots:give_op():map(function()
      return entry.value
    end)
  end, self._get_footprint)
end

function FIFO:put(item)
  return perform(self:put_op(item))
end

function FIFO:get()
  return perform(self:get_op())
end

return FIFO

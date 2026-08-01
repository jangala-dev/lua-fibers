-- Transactional FIFO built from Index + Counter.

local Op = require('fibers.op')
local Index = require('fibers.resource.index')
local Counter = require('fibers.resource.counter')
local Direct = require('fibers.internal.direct')

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

  return get:and_then(Op.guard(function(entry)
    return self._slots:give_op():map(function()
      return entry.value
    end)
  end))
end

Direct.install(FIFO, { 'put', 'get' })

return FIFO

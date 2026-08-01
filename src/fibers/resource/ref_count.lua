local Counter = require('fibers.resource.counter')
local Cell = require('fibers.resource.cell')
local Op = require('fibers.op')
local Direct = require('fibers.internal.direct')

local RefCount = {}
local Handle = {}

RefCount.__index = RefCount
Handle.__index = Handle

local function child_name(name, suffix)
  return name and name .. ':' .. suffix or nil
end

local function handle(group, active)
  group._next_id = group._next_id + 1
  return setmetatable({
    _group = group,
    _active = Cell.new(active, child_name(group._name, 'handle-' .. group._next_id)),
  }, Handle)
end

function RefCount.new(name)
  local group = setmetatable({
    _name = name,
    _count = Counter.new(1, child_name(name, 'count')),
    _next_id = 0,
  }, RefCount)
  return group, handle(group, true)
end

function RefCount:count_op()
  return self._count:read_op()
end

function RefCount:zero_op()
  return self._count:zero_op()
end

function Handle:active_op()
  return self._active:expect_op(true)
end

function Handle:inactive_op()
  return self._active:expect_op(false)
end

function Handle:clone_op()
  local group = self._group
  local clone = self:active_op():and_then(group._count:give_op(1)):wrap(function()
    return handle(group, true)
  end)

  return clone:or_else(self:inactive_op():wrap(function()
    return handle(group, false)
  end))
end

function Handle:close_op()
  local close = self:active_op():and_then(Op.each({
    self._active:write_op(false),
    self._group._count:take_op(1),
  }):map(function()
    return true
  end))

  return close:or_else(self:inactive_op():map(function()
    return false
  end))
end

RefCount.Handle = Handle

Direct.install(RefCount, { 'count', 'zero' })
Direct.install(Handle, { 'active', 'inactive', 'clone', 'close' })

return RefCount

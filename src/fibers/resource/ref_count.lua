local Counter = require('fibers.resource.counter')
local Cell = require('fibers.resource.cell')
local Op = require('fibers.op')
local Direct = require('fibers.internal.direct')
local Label = require('fibers.internal.label')

local RefCount = {}
local Handle = {}
local next_id = 0

RefCount.__index = RefCount
Handle.__index = Handle

local function handle(group, active)
  group._next_id = group._next_id + 1
  local id = group._fibers_id .. ':handle-' .. tostring(group._next_id)
  local value = Label.attach(setmetatable({
    _fibers_id = id,
    _group = group,
    _active = Cell.new(active),
  }, Handle))
  Label.child(value, group, 'handle-' .. tostring(group._next_id))
  Label.child(value._active, value, 'active')
  return value
end

function RefCount.new()
  next_id = next_id + 1
  local id = 'ref-count-' .. tostring(next_id)
  local group = Label.attach(setmetatable({
    _fibers_id = id,
    name = id,
    _count = Counter.new(1),
    _next_id = 0,
  }, RefCount))
  Label.child(group._count, group, 'count')
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

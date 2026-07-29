local Op = require('fibers.op')
local Cell = require('fibers.resource.cell')
local perform = require('fibers.perform')

local Latch = {}
Latch.__index = Latch

local EMPTY = {}
local NIL = {}

local function encode(value)
  return value == nil and NIL or value
end

local function decode(value)
  return value == NIL and nil or value
end

function Latch.new(name)
  return setmetatable({ _state = Cell.new(EMPTY, name) }, Latch)
end

function Latch:set_op(value)
  local set = self._state:expect_op(EMPTY):and_then(function()
    return self._state:write_op(encode(value)):map(function()
      return true
    end)
  end)

  return set:or_else(self._state
    :wait_until_op(function(current)
      return current ~= EMPTY
    end)
    :map(function()
      return false
    end))
end

function Latch:get_op()
  return self._state
    :wait_until_op(function(value)
      return value ~= EMPTY
    end)
    :map(decode)
end

function Latch:is_set_op()
  return self._state:read_op():map(function(value)
    return value ~= EMPTY
  end)
end

function Latch:set(value)
  return perform(self:set_op(value))
end

function Latch:get()
  return perform(self:get_op())
end

function Latch:is_set()
  return perform(self:is_set_op())
end

return Latch

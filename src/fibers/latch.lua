local Cell = require('fibers.resource.cell')
local Direct = require('fibers.internal.direct')

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
  local set = self._state:expect_op(EMPTY):and_then(self._state:write_op(encode(value)):map(function()
      return true
    end))

  return set:or_else(self._state:wait_until_op(function(current)
    return current ~= EMPTY
  end):map(function()
    return false
  end))
end

function Latch:get_op()
  return self._state:wait_until_op(function(value)
    return value ~= EMPTY
  end):map(decode)
end

function Latch:is_set_op()
  return self._state:read_op():map(function(value)
    return value ~= EMPTY
  end)
end




Direct.install(Latch, { 'set', 'get', 'is_set' })

return Latch

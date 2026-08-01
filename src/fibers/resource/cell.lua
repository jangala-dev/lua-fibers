local Facility = require('fibers.resource.authoring')
local Op = require('fibers.op')
local Operation = require('fibers.internal.operation')
local Values = require('fibers.internal.values')
local Direct = require('fibers.internal.direct')

local Cell = {}
Cell.__index = function(self, key)
  if key == 'value' then
    return self._location.value
  end
  if key == 'version' then
    return self._location.version
  end
  return Cell[key]
end

local Kind = Facility.kind('cell')

local function select_op(resource, select)
  local function loop()
    return resource._state_op:and_then(Op.guard(function(state)
      local option, wait = select(state.value)
      if option ~= nil then
        return option
      end
      if wait == false then
        return Op.never()
      end
      return Operation.bind(resource._changed_spec, state.version):and_then(Op.guard(loop))
    end))
  end
  return loop()
end

function Cell.new(value, name)
  local cell = Facility.identity(setmetatable({}, Cell), Kind, name)
  return Facility.cell(cell, value)
end

function Cell:read_op()
  return self._read_op
end

function Cell:changed_op(version)
  return Facility.bind(self._changed_spec, version)
end

function Cell:expect_op(value)
  return Facility.bind(self._expect_spec, value)
end

function Cell:write_op(value)
  return Facility.bind(self._write_spec, value)
end

function Cell:select_op(select)
  return select_op(self, select)
end

function Cell:wait_until_op(predicate)
  return select_op(self, function(value)
    if predicate(value) then
      return Op.always(value)
    end
  end)
end

function Cell:match_op(matcher)
  return select_op(self, function(value)
    local result = Values.pack(matcher(value))
    if result[1] then
      return Op.always(Values.unpack(result, 2, result.n))
    end
  end)
end

Direct.install(Cell, { 'read', 'changed', 'expect', 'write', 'wait_until', 'match' })

Cell.Kind = Kind

return Cell

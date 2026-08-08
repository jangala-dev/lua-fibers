local Facility = require('fibers.resource.authoring')
local Op = require('fibers.op')
local Direct = require('fibers.internal.direct')

local Cell = {}
Cell.__index = Cell

local Kind = Facility.kind('cell')

local VERSIONED_RESULT = Facility.result.project(function(value, leaf)
  return { value = value, version = leaf.location.version }
end)

local function select_op(resource, select)
  local function loop()
    return resource._state_op:and_then(Op.guard(function(state)
      local option, wait = select(state.value)
      if option ~= nil then return option end
      if wait == false then return Op.never() end
      return Facility.bind(resource._changed_spec, state.version):and_then(Op.guard(loop))
    end))
  end
  return loop()
end

function Cell._init(resource, value, algebra)
  resource._location = Facility.location(resource, {
    algebra = algebra or 'replace',
    domain = 'plain',
    value = value,
  })
  resource._read_op = Facility.op(Facility.read(resource._location, Facility.result.value, resource))
  resource._state_op = Facility.op(Facility.read(resource._location, VERSIONED_RESULT, resource))
  resource._write_spec = Facility.replace(resource._location, Facility.result.boolean, resource)
  resource._changed_spec = Facility.version_wait(resource._location, resource)
  resource._expect_spec = Facility.rule.inspect({
    location = resource._location,
    resource = resource,
    step = function(current, expected)
      if current ~= expected then return nil end
      return Facility.outcome(nil, true)
    end,
  })
  return resource
end

function Cell.new(value)
  local cell = Facility.identity(setmetatable({}, Cell), Kind)
  return Cell._init(cell, value)
end

function Cell:read_op()
  return self._read_op
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
    if predicate(value) then return Op.always(value) end
  end)
end

function Cell:match_op(matcher)
  return select_op(self, function(value)
    local result = Facility.pack(matcher(value))
    if result[1] then return Op.always(Facility.unpack(result, 2, result.n)) end
  end)
end

Direct.install(Cell, { 'read', 'expect', 'write', 'wait_until', 'match' })

Cell.Kind = Kind

return Cell

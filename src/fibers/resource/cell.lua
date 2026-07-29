local Facility = require('fibers.resource.authoring')
local perform = require('fibers.perform')

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

function Cell.new(value, name)
  local cell = Facility.identity(setmetatable({}, Cell), Kind, name)
  return Facility.cell(cell, Kind, value)
end

function Cell:read_op()
  return self._read_op
end

function Cell:read()
  return perform(self:read_op())
end

function Cell:changed_op(version)
  return Facility.occurrence(self._changed_descriptor, version)
end

function Cell:changed(version)
  return perform(self:changed_op(version))
end

function Cell:expect_op(value)
  return Facility.occurrence(self._expect_descriptor, value)
end

function Cell:expect(value)
  return perform(self:expect_op(value))
end

function Cell:write_op(value)
  return Facility.occurrence(self._write_descriptor, value)
end

function Cell:write(value)
  return perform(self:write_op(value))
end

function Cell:select_op(select, dependencies)
  return Facility.versioned_select(self, select, dependencies)
end

function Cell:wait_until_op(predicate, dependencies)
  return Facility.versioned_wait_until(self, predicate, dependencies)
end

function Cell:wait_until(predicate, dependencies)
  return perform(self:wait_until_op(predicate, dependencies))
end

function Cell:match_op(matcher, dependencies)
  return Facility.versioned_match(self, matcher, dependencies)
end

function Cell:match(matcher, dependencies)
  return perform(self:match_op(matcher, dependencies))
end

Cell.Kind = Kind

return Cell

local Facility = require('fibers.resource.authoring')

local Scalar = {}
Scalar.__index = function(self, key)
  if key == 'value' then
    return self._location.value
  end
  if key == 'version' then
    return self._location.version
  end
  return Scalar[key]
end

local Kind = Facility.kind('scalar')

function Scalar.new(value, name)
  local scalar = Facility.identity(setmetatable({}, Scalar), Kind, name)
  return Facility.cell(scalar, Kind, value)
end

function Scalar:read_op()
  return self._read_op
end

function Scalar:changed_op(version)
  return Facility.occurrence(self._changed_descriptor, version)
end

function Scalar:expect_op(value)
  return Facility.occurrence(self._expect_descriptor, value)
end

function Scalar:write_op(value)
  return Facility.occurrence(self._write_descriptor, value)
end

function Scalar:select_op(select, dependencies)
  return Facility.versioned_select(self, select, dependencies)
end

function Scalar:until_op(predicate, dependencies)
  return Facility.versioned_until(self, predicate, dependencies)
end

function Scalar:value_op(predicate, dependencies)
  return Facility.versioned_value(self, predicate, dependencies)
end

Scalar.Kind = Kind
Facility.performing(Scalar, { 'read', 'changed', 'expect', 'write' })

return Scalar

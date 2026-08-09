local Facility = require('fibers.resource.authoring')
local Op = require('fibers.op')
local Direct = require('fibers.internal.direct')

local Cell = {}
Cell.__index = Cell

local Kind = Facility.kind('cell')

local VERSIONED_RESULT = Facility.result.project(function(value, leaf)
  return { value = value, version = leaf.location.version }
end)

local function expect(current, expected)
  if current == expected then return Facility.outcome(nil, true) end
end

local function select_op(resource, select)
  local state = resource._state_op
  if not state then
    state = Facility.op(Facility.read(resource._location, VERSIONED_RESULT, resource))
    resource._state_op = state
  end
  local changed = resource._changed_spec
  if not changed then
    changed = Facility.version_wait(resource._location, resource)
    resource._changed_spec = changed
  end
  local function loop()
    return state:and_then(Op.guard(function(current)
      local option, wait = select(current.value)
      if option ~= nil then return option end
      if wait == false then return Op.never() end
      return Facility.bind(changed, current.version):and_then(Op.guard(loop))
    end))
  end
  return loop()
end

function Cell._init(resource, value, algebra)
  resource._location = Facility.location(resource, {
    algebra = algebra or 'replace', domain = 'plain', value = value,
  })
  return resource
end

function Cell.new(value)
  local cell = Facility.identity(setmetatable({}, Cell), Kind)
  return Cell._init(cell, value)
end

function Cell:read_op()
  local op = self._read_op
  if not op then
    op = Facility.op(Facility.read(self._location, Facility.result.value, self))
    self._read_op = op
  end
  return op
end

function Cell:expect_op(value)
  local spec = self._expect_spec
  if not spec then
    spec = Facility.rule.inspect({ location = self._location, resource = self, step = expect })
    self._expect_spec = spec
  end
  return Facility.bind(spec, value)
end

function Cell:write_op(value)
  local spec = self._write_spec
  if not spec then
    spec = Facility.replace(self._location, Facility.result.boolean, self)
    self._write_spec = spec
  end
  return Facility.bind(spec, value)
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

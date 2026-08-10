local Facility = require('fibers.resource.authoring')
local Op = require('fibers.op')
local Direct = require('fibers.internal.direct')
local StateResource = require('fibers.internal.state_resource')
local ValueSemantics = require('fibers.internal.value_semantics')

local Cell = {}
Cell.__index = Cell

local Kind = Facility.kind('cell')

local VERSIONED_RESULT = Facility.result.project(function(value, leaf)
  return { value = value, version = leaf.location.version }
end)

local function read_result(resource)
  local semantics = resource._value_semantics
  return Facility.result.project(function(value)
    return semantics.expose(value)
  end)
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
      -- The versioned read stays internal. Arbitrary selection code receives an
      -- exposure, never the authoritative representation. The raw value is only
      -- passed to private selectors which need to produce a pristine result.
      local working = resource._value_semantics.expose(current.value)
      local option, wait = select(working, current.value)
      if option ~= nil then return option end
      if wait == false then return Op.never() end
      return Facility.bind(changed, current.version):and_then(Op.guard(loop))
    end))
  end
  return loop()
end

function Cell.new(value)
  local cell = Facility.identity(setmetatable({}, Cell), Kind)
  return StateResource.init(cell, value, 'replace', ValueSemantics.managed, 'Cell.new() value')
end

function Cell:read_op()
  local op = self._read_op
  if not op then
    op = Facility.op(Facility.read(self._location, read_result(self), self))
    self._read_op = op
  end
  return op
end

function Cell:expect_op(value)
  local semantics = self._value_semantics
  value = semantics.capture(value, 'Cell:expect_op() value', 3)
  local spec = self._expect_spec
  if not spec then
    spec = Facility.rule.inspect({
      location = self._location,
      resource = self,
      step = function(current, expected)
        if semantics.equal(current, expected) then return Facility.outcome(nil, true) end
      end,
    })
    self._expect_spec = spec
  end
  return Facility.bind(spec, value)
end

function Cell:write_op(value)
  local semantics = self._value_semantics
  value = semantics.capture(value, 'Cell:write_op() value', 3)
  local spec = self._write_spec
  if not spec then
    spec = Facility.replace(self._location, Facility.result.boolean, self)
    self._write_spec = spec
  end
  return Facility.bind(spec, value)
end

function Cell:select_op(select)
  return select_op(self, function(value) return select(value) end)
end

function Cell:wait_until_op(predicate)
  local semantics = self._value_semantics
  return select_op(self, function(value, authoritative)
    if predicate(value) then
      -- Return a fresh exposure of the observed authoritative value rather than
      -- the predicate's disposable working copy.
      return Op.always(semantics.expose(authoritative))
    end
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

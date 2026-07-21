local Op = require('fibers.op')
local Facility = require('fibers.internal.facility')
local Algebra = require('fibers.internal.kernel.algebra')

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
local WAIT = { _fibers_scalar_wait = true }
local Ready = {}
function Ready.write(value, ...)
  return { _fibers_scalar_ready = true, writes = true, value = value, pack = Op._pack(...) }
end
function Ready.same(...)
  return { _fibers_scalar_ready = true, writes = false, pack = Op._pack(...) }
end
Scalar.Wait = WAIT
Scalar.Ready = Ready

function Scalar.transition(spec)
  if type(spec) ~= 'table' then
    error('Scalar.transition expects a table', 2)
  end
  if type(spec.step) ~= 'function' and type(spec.apply) ~= 'function' then
    error('Scalar.transition requires step or apply', 2)
  end
  if spec.supply ~= nil then
    error('Scalar.transition no longer accepts supply; use accepts_supply and supplies', 2)
  end
  local mode = spec.mode or 'update'
  if mode ~= 'update' and mode ~= 'select' and mode ~= 'query' then
    error('scalar transition mode must be update, select, or query', 2)
  end
  if type(spec.accepts_supply) ~= 'boolean' then
    error('Scalar.transition requires accepts_supply = true or false', 2)
  end
  local supplies = Facility.normalise_supply(spec.supplies, 'Scalar.transition supplies', 2)
  if mode == 'query' and not Facility.supply_empty(supplies) then
    error('query transitions cannot declare supplied state', 2)
  end
  return {
    _fibers_transition_rule = true,
    type = 'machine',
    serial = true,
    enumerable = false,
    eager = false,
    total = mode == 'update',
    writes = mode ~= 'query',
    name = spec.name,
    mode = mode,
    step = spec.step or spec.apply,
    ready = spec.ready,
    validate = spec.validate,
    order = spec.order or 0,
    accepts_supply = spec.accepts_supply,
    supplies = supplies,
  }
end

function Scalar.kind(spec)
  if type(spec) ~= 'table' then
    error('Scalar.kind expects a table', 2)
  end
  local k = { name = spec.name or '<scalar-kind>', transitions = {} }
  for name, tspec in pairs(spec.transitions or {}) do
    local full = {}
    for kk, vv in pairs(tspec) do
      full[kk] = vv
    end
    full.name = full.name or (k.name .. '.' .. tostring(name))
    k.transitions[name] = Scalar.transition(full)
  end
  function k:transition(name)
    local t = self.transitions[name]
    if not t then
      error('unknown scalar transition ' .. tostring(name), 2)
    end
    return t
  end
  return k
end

local function new_scalar(value, name, merge)
  local scalar = Facility.identity(setmetatable({}, Scalar), Kind, name)
  scalar._location = Facility.location(scalar, 'value', {
    algebra = merge or 'replace',
    domain = 'plain',
    value = value,
  })
  scalar._read_op = Facility.static(scalar, Kind, 'read', {
    location = scalar._location,
    result = Facility.result.value,
  })
  scalar._snapshot_op = Facility.static(scalar, Kind, 'read', {
    location = scalar._location,
    result = Facility.result.scalar_snapshot,
  })
  scalar._write_descriptor = Facility.descriptor(scalar, Kind, 'patch', {
    location = scalar._location,
    payload_patch = 'replace',
    result = Facility.result.boolean,
  })
  return scalar
end

function Scalar.new(value, name)
  return new_scalar(value, name, 'replace')
end
function Scalar.machine(value, name)
  return new_scalar(value, name, 'machine')
end

function Scalar:read_op()
  return self._read_op
end

function Scalar:snapshot_op()
  return self._snapshot_op
end

function Scalar:changed_op(version)
  return Facility.static(self, Kind, 'version_wait', { location = self._location, version = version })
end

function Scalar:expect_op(value)
  local scalar = self
  local t = Scalar.transition({
    name = self.name .. ':expect',
    mode = 'query',
    accepts_supply = false,
    supplies = 'none',
    step = function(current)
      if current ~= value then
        return Scalar.Wait
      end
      return Scalar.Ready.same(true)
    end,
  })
  return scalar:transition_op(t, {})
end

function Scalar:unsafe_update_op(fn)
  if type(fn) ~= 'function' then
    error('scalar unsafe_update expects a function', 2)
  end
  local t = Scalar.transition({
    mode = 'update',
    accepts_supply = true,
    supplies = 'any',
    step = function(current)
      return fn(current)
    end,
  })
  return self:transition_op(t, {})
end

function Scalar:unsafe_select_op(fn)
  if type(fn) ~= 'function' then
    error('scalar unsafe_select expects a function', 2)
  end
  local t = Scalar.transition({
    mode = 'select',
    accepts_supply = true,
    supplies = 'any',
    step = function(current)
      return fn(current)
    end,
  })
  return self:transition_op(t, {})
end

function Scalar:write_op(value)
  if self._location.algebra.name == 'machine' then
    local transition = Scalar.transition({
      mode = 'update',
      accepts_supply = true,
      supplies = 'any',
      order = 0,
      step = function()
        return value, true
      end,
    })
    return self:transition_op(transition, {})
  end
  return Facility.occurrence(self._write_descriptor, value)
end

function Scalar:transition_op(transition, payload)
  if type(transition) ~= 'table' or transition._fibers_transition_rule ~= true then
    error('scalar transition expected', 2)
  end
  payload = payload or {}
  if self._location.algebra.name == 'replace' then
    self._location.algebra = Algebra.get('machine')
  end
  if transition.validate then
    transition.validate(payload)
  end
  return Facility.op(self, Kind, Facility.machine(self._location, transition, payload, self))
end

Scalar.Kind = Kind

Facility.performing(Scalar, { 'read', 'changed', 'expect', 'write' })

return Scalar

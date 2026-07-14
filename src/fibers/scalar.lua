local Op = require('fibers.op')
local Substrate = require('fibers.internal.kernel.store')

local Scalar = {}
Scalar.__index = Scalar

local Kind = { name = 'scalar' }
local next_id = 0
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
  local mode = spec.mode or 'update'
  if mode ~= 'update' and mode ~= 'select' and mode ~= 'query' then
    error('scalar transition mode must be update, select, or query', 2)
  end
  return {
    _fibers_scalar_transition = true,
    name = spec.name,
    mode = mode,
    step = spec.step or spec.apply,
    ready = spec.ready,
    validate = spec.validate,
    order = spec.order or 0,
    supply = spec.supply or 'interacting',
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
  next_id = next_id + 1
  local scalar = setmetatable({
    value = value,
    version = 0,
    name = name or ('scalar-' .. tostring(next_id)),
    _fibers_id = 'scalar-' .. tostring(next_id),
    _fibers_kind = Kind,
  }, Scalar)
  scalar._location = Substrate.new_location({
    name = scalar.name .. ':value',
    merge = merge or 'replace',
    domain = 'plain',
    value = value,
    owner = scalar,
    apply = function(v, loc)
      scalar.value = v
      scalar.version = loc.version
    end,
  })
  scalar._read_op = Op._compact_resource(scalar, Kind, 'read', {
    location = scalar._location,
    result_kind = 'identity',
  })
  scalar._snapshot_op = Op._compact_resource(scalar, Kind, 'read', {
    location = scalar._location,
    result_kind = 'scalar_snapshot',
  })
  scalar._write_descriptor = Op._compact_descriptor(scalar, Kind, 'patch', {
    location = scalar._location,
    payload_patch = 'replace',
    result_kind = 'constant',
    result_value = true,
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
  return Op._compact_resource(self, Kind, 'version_wait', { location = self._location, version = version })
end

function Scalar:expect_op(value)
  local scalar = self
  local t = Scalar.transition({
    name = self.name .. ':expect',
    mode = 'query',
    supply = 'none',
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
    step = function(current)
      return fn(current)
    end,
  })
  return self:transition_op(t, {})
end

function Scalar:write_op(value)
  if self._location.merge == 'machine' then
    local transition = Scalar.transition({
      mode = 'update',
      order = 0,
      step = function()
        return value, true
      end,
    })
    return self:transition_op(transition, {})
  end
  return Op._compact_occurrence(self._write_descriptor, value)
end

function Scalar:transition_op(transition, payload)
  if type(transition) ~= 'table' or transition._fibers_scalar_transition ~= true then
    error('scalar transition expected', 2)
  end
  payload = payload or {}
  if self._location.merge == 'replace' then
    self._location.merge = 'machine'
  end
  if transition.validate then
    transition.validate(payload)
  end
  return Op._compact_resource(self, Kind, 'machine_transition', {
    location = self._location,
    transition = transition,
    payload = payload,
    resource = self,
    order = transition.order or 0,
  })
end

Scalar.Kind = Kind
return Scalar

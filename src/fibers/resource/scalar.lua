local Op = require('fibers.op')
local Facility = require('fibers.resource.authoring')
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
local SNAPSHOT_RESULT = Facility.result.project(function(value, program)
  return { value = value, version = program.location.version }
end)
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

local WRITE_TRANSITION
local EXPECT_TRANSITION

function Scalar.transition(spec)
  if type(spec) ~= 'table' then
    error('Scalar.transition expects a table', 2)
  end
  if type(spec.step) ~= 'function' then
    error('Scalar.transition requires step', 2)
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
    step = spec.step,
    ready = spec.ready,
    validate = spec.validate,
    order = spec.order or 0,
    accepts_supply = spec.accepts_supply,
    supplies = supplies,
  }
end

WRITE_TRANSITION = Scalar.transition({
  name = 'scalar.write',
  mode = 'update',
  accepts_supply = true,
  supplies = 'any',
  step = function(_, value)
    return Ready.write(value, true)
  end,
})
EXPECT_TRANSITION = Scalar.transition({
  name = 'scalar.expect',
  mode = 'query',
  accepts_supply = false,
  supplies = 'none',
  step = function(current, expected)
    if current ~= expected then
      return WAIT
    end
    return Ready.same(true)
  end,
})

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
    result = SNAPSHOT_RESULT,
  })
  scalar._write_descriptor = Facility.descriptor(scalar, Kind, 'patch', {
    location = scalar._location,
    bind = 'replace',
    result = Facility.result.boolean,
  })
  scalar._changed_descriptor = Facility.descriptor(scalar, Kind, 'version_wait', {
    location = scalar._location,
    bind = 'version',
  })
  -- Descriptors retain their transition rule.  Weak keys alone rely on
  -- ephemeron semantics, which Lua 5.1 and LuaJIT do not provide: the value
  -- then keeps the key, and dynamic transition closures remain reachable.
  -- Weak values make the cache advisory on every supported interpreter.
  scalar._transition_descriptors = setmetatable({}, { __mode = 'kv' })
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
  return Facility.occurrence(self._changed_descriptor, version)
end

function Scalar:expect_op(value)
  return self:transition_op(EXPECT_TRANSITION, value)
end

function Scalar:write_op(value)
  if self._location.algebra.name == 'machine' then
    return self:transition_op(WRITE_TRANSITION, value)
  end
  return Facility.occurrence(self._write_descriptor, value)
end

function Scalar:transition_op(transition, payload)
  if type(transition) ~= 'table' or transition._fibers_transition_rule ~= true then
    error('scalar transition expected', 2)
  end
  if self._location.algebra.name == 'replace' then
    self._location.algebra = Algebra.get('machine')
  end
  if transition.validate then
    transition.validate(payload)
  end
  local descriptor = self._transition_descriptors[transition]
  if not descriptor then
    descriptor =
      Facility.descriptor(self, Kind, 'transition', Facility.machine(self._location, transition, nil, self))
    self._transition_descriptors[transition] = descriptor
  end
  return Facility.occurrence(descriptor, payload)
end

Scalar.Kind = Kind

Facility.performing(Scalar, { 'read', 'changed', 'expect', 'write' })

-- Versioned waits over Scalar resources.
local unpack_ = table.unpack or unpack

local function pack(...)
  return { n = select('#', ...), ... }
end

local function footprint(scalar, writable)
  if not writable then
    return Op.dependencies(scalar:snapshot_op(), scalar:changed_op(0))
  end
  return {
    external = true,
    locations = {
      [scalar._location] = {
        read = true,
        write = true,
        wait = true,
        supplies = { any = true },
      },
    },
  }
end

function Scalar.select_op(scalar, select, opts)
  opts = opts or {}
  local dependencies = opts.footprint or footprint(scalar, opts.writable == true)
  local function loop()
    return scalar:snapshot_op():and_then(function(snapshot)
      local option, wait = select(snapshot.value)
      if option ~= nil then
        return option
      end
      if wait == false then
        return Op.never()
      end
      return scalar:changed_op(snapshot.version):and_then(loop, dependencies)
    end, dependencies)
  end
  return loop()
end

function Scalar.until_op(scalar, predicate, opts)
  return Scalar.select_op(scalar, function(value)
    local result = pack(predicate(value))
    if result[1] then
      return Op.always(unpack_(result, 2, result.n))
    end
  end, opts)
end

function Scalar.value_op(scalar, predicate, opts)
  return Scalar.select_op(scalar, function(value)
    if predicate(value) then
      return Op.always(value)
    end
  end, opts)
end

return Scalar

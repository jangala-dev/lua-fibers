local Op = require('fibers.op')
local Facility = require('fibers.resource.authoring')
local Scalar = require('fibers.resource.scalar')

local Machine = {}
Machine.__index = function(self, key)
  if key == 'value' then
    return self._location.value
  end
  if key == 'version' then
    return self._location.version
  end
  return Machine[key] or Scalar[key]
end

local Kind = Facility.kind('machine')
local MODES = {
  update = { total = true, writes = true },
  select = { total = false, writes = true },
  query = { total = false, writes = false },
}

local WAIT = { _fibers_scalar_wait = true }
local Ready = {}

function Ready.write(value, ...)
  return { _fibers_scalar_ready = true, writes = true, value = value, pack = Op._pack(...) }
end

function Ready.same(...)
  return { _fibers_scalar_ready = true, writes = false, pack = Op._pack(...) }
end

Machine.Wait = WAIT
Machine.Ready = Ready

local function rule(name, mode, step, accepts_supply, supplies, order, ready, validate)
  local semantics = assert(MODES[mode], 'unknown machine transition mode')
  return {
    _fibers_transition_rule = true,
    type = 'machine',
    serial = true,
    enumerable = false,
    eager = false,
    total = semantics.total,
    writes = semantics.writes,
    name = name,
    mode = mode,
    step = step,
    ready = ready,
    validate = validate,
    order = order or 0,
    accepts_supply = accepts_supply,
    supplies = semantics.writes and Facility.normalise_supply(supplies or 'none') or {},
  }
end

function Machine.update(name, step, order, validate)
  return rule(name, 'update', step, true, 'any', order, nil, validate)
end

function Machine.isolated_update(name, step, order, validate)
  return rule(name, 'update', step, false, 'none', order, nil, validate)
end

function Machine.select(name, step, order, validate)
  return rule(name, 'select', step, true, 'any', order, nil, validate)
end

function Machine.select_when(name, ready, step, order, validate)
  return rule(name, 'select', step, true, 'any', order, ready, validate)
end

function Machine.isolated_select(name, step, order, validate)
  return rule(name, 'select', step, false, 'none', order, nil, validate)
end

function Machine.isolated_select_when(name, ready, step, order, validate)
  return rule(name, 'select', step, false, 'none', order, ready, validate)
end

function Machine.query(name, step, order, validate)
  return rule(name, 'query', step, true, 'none', order, nil, validate)
end

function Machine.query_when(name, ready, step, order, validate)
  return rule(name, 'query', step, true, 'none', order, ready, validate)
end

function Machine.isolated_query(name, step, order, validate)
  return rule(name, 'query', step, false, 'none', order, nil, validate)
end

function Machine.isolated_query_when(name, ready, step, order, validate)
  return rule(name, 'query', step, false, 'none', order, ready, validate)
end

-- Low-level form for transitions with unusual supply contracts.
function Machine.rule(name, mode, step, accepts_supply, supplies, order, ready, validate)
  return rule(name, mode, step, accepts_supply, supplies, order, ready, validate)
end

local WRITE = Machine.update('machine.write', function(_, value)
  return Ready.write(value, true)
end)

function Machine.new(value, name)
  local machine = Facility.identity(setmetatable({}, Machine), Kind, name)
  Facility.cell(machine, Kind, value, 'machine')
  machine._transition_dependencies = Facility.versioned_dependencies(machine, true)
  machine._transition_descriptors = setmetatable({}, { __mode = 'kv' })
  return machine
end

function Machine:write_op(value)
  return self:transition_op(WRITE, value)
end

function Machine:transition_dependencies()
  return self._transition_dependencies
end

function Machine:transition_op(transition, payload)
  assert(transition and transition._fibers_transition_rule, 'machine transition expected')
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

Machine.Kind = Kind

return Machine

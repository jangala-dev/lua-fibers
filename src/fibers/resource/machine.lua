local Values = require('fibers.internal.values')
local Facility = require('fibers.resource.authoring')
local Cell = require('fibers.resource.cell')

local unpack_ = table.unpack or unpack

local Machine = {}
Machine.__index = function(self, key)
  if key == 'value' then
    return self._location.value
  end
  if key == 'version' then
    return self._location.version
  end
  return Machine[key] or Cell[key]
end

local Kind = Facility.kind('machine')
local MODES = {
  update = { total = true, writes = true },
  select = { total = false, writes = true },
  query = { total = false, writes = false },
}

local WAIT = { _fibers_cell_wait = true }
local Ready = {}

function Ready.write(value, ...)
  return { _fibers_cell_ready = true, writes = true, value = value, pack = Values.pack(...) }
end

function Ready.same(...)
  return { _fibers_cell_ready = true, writes = false, pack = Values.pack(...) }
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

local function define_rule_constructor(method, mode, accepts_supply, supplies, with_ready)
  if with_ready then
    Machine[method] = function(name, ready, step, order, validate)
      return rule(name, mode, step, accepts_supply, supplies, order, ready, validate)
    end
  else
    Machine[method] = function(name, step, order, validate)
      return rule(name, mode, step, accepts_supply, supplies, order, nil, validate)
    end
  end
end

for _, spec in ipairs({
  { 'update', 'update', true, 'any' },
  { 'isolated_update', 'update', false, 'none' },
  { 'select', 'select', true, 'any' },
  { 'select_when', 'select', true, 'any', true },
  { 'isolated_select', 'select', false, 'none' },
  { 'isolated_select_when', 'select', false, 'none', true },
  { 'query', 'query', true, 'none' },
  { 'query_when', 'query', true, 'none', true },
  { 'isolated_query', 'query', false, 'none' },
  { 'isolated_query_when', 'query', false, 'none', true },
}) do
  define_rule_constructor(unpack_(spec))
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
  Facility.cell(machine, value, 'machine')
  machine._transition_specs = setmetatable({}, { __mode = 'kv' })
  return machine
end

function Machine:write_op(value)
  return self:transition_op(WRITE, value)
end

function Machine:transition_op(transition, payload)
  assert(transition and transition._fibers_transition_rule, 'machine transition expected')
  if transition.validate then
    transition.validate(payload)
  end
  local spec = self._transition_specs[transition]
  if not spec then
    spec = Facility.machine_transition({ location = self._location, resource = self }, transition)
    self._transition_specs[transition] = spec
  end
  return Facility.bind(spec, payload)
end

Machine.Kind = Kind

return Machine

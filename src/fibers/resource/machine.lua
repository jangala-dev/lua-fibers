local Facility = require('fibers.resource.authoring')
local Cell = require('fibers.resource.cell')

local unpack_ = table.unpack or unpack

local Machine = {}
Machine.__index = function(_, key)
  return Machine[key] or Cell[key]
end

local Kind = Facility.kind('machine')
local MODES = {
  update = { total = true, mode = 'change' },
  select = { total = false, mode = 'change' },
  query = { total = false, mode = 'inspect' },
}

local WAIT = { _fibers_cell_wait = true }
local Ready = {}

local function copy_supply(value)
  if type(value) ~= 'table' then return value end
  local out = {}
  for key, present in pairs(value) do out[key] = present end
  return out
end

function Ready.write(value, ...)
  return { _fibers_cell_ready = true, writes = true, value = value, pack = Facility.pack(...) }
end

function Ready.same(...)
  return { _fibers_cell_ready = true, writes = false, pack = Facility.pack(...) }
end

Machine.Wait = WAIT
Machine.Ready = Ready

local function rule(name, mode, step, visibility, supply, order, probe, validate)
  local semantics = assert(MODES[mode], 'unknown machine transition mode')
  return {
    _fibers_transition_rule = true,
    name = name,
    rule_mode = semantics.mode,
    total = semantics.total,
    step = step,
    probe = probe,
    validate = validate,
    serial_order = order or 0,
    visibility = visibility,
    supply = semantics.mode == 'change' and copy_supply(supply or 'none') or 'none',
  }
end

local function define_rule_constructor(method, mode, visibility, supply, with_probe)
  if with_probe then
    Machine[method] = function(name, probe, step, order, validate)
      return rule(name, mode, step, visibility, supply, order, probe, validate)
    end
  else
    Machine[method] = function(name, step, order, validate)
      return rule(name, mode, step, visibility, supply, order, nil, validate)
    end
  end
end

for _, spec in ipairs({
  { 'update', 'update', 'together', 'any' },
  { 'isolated_update', 'update', 'own', 'none' },
  { 'select', 'select', 'together', 'any' },
  { 'select_when', 'select', 'together', 'any', true },
  { 'isolated_select', 'select', 'own', 'none' },
  { 'isolated_select_when', 'select', 'own', 'none', true },
  { 'query', 'query', 'together', 'none' },
  { 'query_when', 'query', 'together', 'none', true },
  { 'isolated_query', 'query', 'own', 'none' },
  { 'isolated_query_when', 'query', 'own', 'none', true },
}) do
  define_rule_constructor(unpack_(spec))
end

-- Low-level façade for unusual but explicit visibility and supply contracts.
function Machine.rule(name, mode, step, visibility, supply, order, probe, validate)
  visibility = visibility or 'own'
  if visibility ~= 'own' and visibility ~= 'together' then
    error('machine rule visibility must be own or together', 2)
  end
  return rule(name, mode, step, visibility, supply, order, probe, validate)
end

local WRITE = Machine.update('machine.write', function(_, value)
  return Ready.write(value, true)
end)

local function argument_or_empty(argument)
  return argument == nil and {} or argument
end

local function compile_transition(location, resource, transition, options)
  options = options or {}
  local function step(value, argument, context)
    local outcome = transition.step(value, argument_or_empty(argument), context)
    if type(outcome) == 'table' and outcome._fibers_cell_wait == true then return nil end
    if not (type(outcome) == 'table' and outcome._fibers_cell_ready == true) then
      error('machine transition must return Machine.Wait or Machine.Ready', 2)
    end
    if transition.rule_mode == 'inspect' and outcome.writes then
      error('query transition cannot write', 2)
    end
    local patch = outcome.writes and Facility.patch.machine(outcome.value) or nil
    return Facility.outcome_packed(patch, outcome.pack or Facility.pack())
  end

  local probe = transition.probe and function(value, argument, context)
    local result = transition.probe(value, argument_or_empty(argument), context)
    return result ~= nil
      and result ~= false
      and not (type(result) == 'table' and result._fibers_cell_wait == true)
  end or nil

  local opts = {
    location = location,
    resource = resource,
    payload = options.payload,
    wake = options.wake,
    visibility = transition.visibility,
    demand = nil,
    serial_order = transition.serial_order,
    step = step,
  }
  if transition.rule_mode == 'change' then opts.supply = transition.supply end
  return Facility._state_rule(transition.rule_mode, opts, {
    name = transition.name,
    total = transition.total,
    probe = probe,
  })
end

function Machine.new(value)
  local machine = Facility.identity(setmetatable({}, Machine), Kind)
  Cell._init(machine, value, 'machine')
  return machine
end

function Machine:write_op(value)
  return self:transition_op(WRITE, value)
end

function Machine:transition_op(transition, payload)
  assert(transition and transition._fibers_transition_rule, 'machine transition expected')
  if transition.validate then transition.validate(payload) end
  local specs = self._transition_specs
  if not specs then specs = setmetatable({}, { __mode = 'kv' }); self._transition_specs = specs end
  local spec = specs[transition]
  if not spec then spec = compile_transition(self._location, self, transition); specs[transition] = spec end
  return Facility.bind(spec, payload)
end

-- Used by external machine-backed resources while retaining the same closed
-- Machine rule protocol.
Machine._compile = compile_transition

Machine.Kind = Kind

return Machine

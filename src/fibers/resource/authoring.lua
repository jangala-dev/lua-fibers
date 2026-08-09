-- Trusted resource-authoring boundary.
--
-- The portable semantic vocabulary is deliberately small:
--   * authoritative Locations;
--   * inspect and change state rules;
--   * linear exchange rules.
--
-- Search metadata which follows from those forms is derived here. Higher-level
-- resources do not construct kernel leaves directly.

local Operation = require('fibers.internal.operation')
local Values = require('fibers.internal.values')
local Journal = require('fibers.internal.kernel.journal')
local Algebra = require('fibers.internal.kernel.algebra')
local Label = require('fibers.internal.label')
local Contract = require('fibers.internal.contract')

local M = {}

local RULE_OPTIONS = {
  location = true,
  payload = true,
  resource = true,
  wake = true,
  step = true,
  cursor = true,
  visibility = true,
  demand = true,
  supply = true,
  serial_order = true,
}

local function validate_keys(value, allowed, label, level)
  return Contract.options(value, allowed, label, level or 3)
end


local LOCATION_OPTIONS = {
  algebra = true,
  domain = true,
  value = true,
  version = true,
  key = true,
  clone_value = true,
  put_equal = true,
  remove_idempotent = true,
}

local ids = {}

function M.kind(name)
  return { _fibers_facility_kind = true, name = Contract.non_empty_string(name, 'facility kind name', 2) }
end

function M.identity(resource, kind)
  if type(resource) ~= 'table' then
    error('facility identity requires a table resource', 2)
  end
  if type(kind) ~= 'table' or kind._fibers_facility_kind ~= true then
    error('facility identity requires a kind created by Facility.kind', 2)
  end
  if rawget(resource, '_fibers_id') ~= nil or rawget(resource, '_fibers_kind') ~= nil then
    error('facility resource already has an identity', 2)
  end
  local prefix = kind.name
  local id = (ids[prefix] or 0) + 1
  ids[prefix] = id
  resource._fibers_id = prefix .. '-' .. tostring(id)
  resource._fibers_kind = kind
  return Label.attach(resource)
end

function M.location(owner, opts)
  if type(owner) ~= 'table' then
    error('Facility.location owner must be a table', 2)
  end
  opts = Contract.options(opts, LOCATION_OPTIONS, 'Facility.location options', 2)
  if opts.algebra == nil then error('Facility.location requires algebra', 2) end
  if opts.version ~= nil then Contract.non_negative_integer(opts.version, 'Facility.location version', 2) end
  Contract.optional_function(opts.clone_value, 'Facility.location clone_value', 2)
  Contract.optional_boolean(opts.put_equal, 'Facility.location put_equal', 2)
  Contract.optional_boolean(opts.remove_idempotent, 'Facility.location remove_idempotent', 2)
  return Journal.new_location(opts, owner)
end

M.ABSENT = Algebra.ABSENT

M.patch = {
  replace = function(value) return { kind = 'replace', value = value } end,
  add = function(delta) return { kind = 'add', delta = delta } end,
  put = function(value) return { kind = 'presence', ops = { { op = 'put', value = value } } } end,
  remove = function() return { kind = 'presence', ops = { { op = 'remove' } } } end,
  take = function() return { kind = 'presence', ops = { { op = 'take' } } } end,
  map_put = function(key, value, policy)
    return { kind = 'finite_map', ops = { { op = 'put', key = key, value = value, policy = policy } } }
  end,
  map_remove = function(key)
    return { kind = 'finite_map', ops = { { op = 'remove', key = key } } }
  end,
  map_take = function(key)
    return { kind = 'finite_map', ops = { { op = 'take', key = key } } }
  end,
  -- A machine successor is compiled into a serial machine patch when staged.
  machine = function(value) return { kind = 'machine_value', value = value } end,
}

M.result = Operation.result
M.pack = Values.pack
M.unpack = Values.unpack

local function is_pack(value)
  return type(value) == 'table' and value._fibers_pack == true
end

function M.op(spec)
  return Operation.op(spec)
end

function M.bind(spec, argument)
  return Operation.bind(spec, argument)
end

function M.read(location, result, resource)
  return Operation.read(location, result or M.result.value, resource)
end

function M.write(location, patch, result, resource)
  return Operation.patch(location, patch, result or M.result.boolean, resource)
end

function M.replace(location, result, resource)
  return Operation.patch(
    location,
    nil,
    result or M.result.boolean,
    resource,
    M.patch.replace,
    { any = true }
  )
end

function M.add(location, result, resource)
  return Operation.patch(location, nil, result or M.result.boolean, resource, M.patch.add)
end

function M.presence_put(location, result, resource)
  return Operation.patch(
    location,
    nil,
    result or M.result.boolean,
    resource,
    M.patch.put,
    { up = true }
  )
end

function M.version_wait(location, resource)
  return Operation.version_wait(location, nil, resource)
end

function M.clock_now(resource)
  return Operation.clock_now(resource)
end

function M.outcome(patch, ...)
  return { patch = patch, result = Values.pack(...) }
end

function M.outcome_packed(patch, packed)
  if not is_pack(packed) then error('packed outcome requires a Fibers value pack', 2) end
  return { patch = patch, result = packed }
end

local function state_spec(opts, transition, internal)
  internal = internal or {}
  return Operation.transition({
    location = opts.location,
    orientation = opts.demand,
    argument = opts.payload,
    resource = opts.resource,
    interest = opts.wake,
    absence_check = internal.absence_check,
    name = internal.name,
    transition = transition,
  })
end

local function validate_rule(mode, opts, level)
  validate_keys(opts, RULE_OPTIONS, mode .. ' rule options', (level or 2) + 1)
  if opts.location == nil then error(mode .. ' rule requires location', (level or 2) + 1) end
  local has_step = type(opts.step) == 'function'
  local has_cursor = type(opts.cursor) == 'function'
  if has_step == has_cursor then
    error(mode .. ' rule requires exactly one of step or cursor', (level or 2) + 1)
  end

  local visibility = opts.visibility or 'own'
  if visibility ~= 'own' and visibility ~= 'together' then
    error(mode .. ' rule visibility must be own or together', (level or 2) + 1)
  end

  if opts.serial_order ~= nil then
    if opts.location.algebra.name ~= 'machine' then
      error('serial_order is only valid for machine locations', (level or 2) + 1)
    end
    if type(opts.serial_order) ~= 'number' then
      error('serial_order must be a number', (level or 2) + 1)
    end
  end

  if mode == 'inspect' and opts.supply ~= nil and opts.supply ~= 'none' then
    error('inspect rule cannot declare outgoing supply', (level or 2) + 1)
  end
  if mode == 'change' and opts.supply == nil then
    error('change rule requires an explicit supply declaration', (level or 2) + 1)
  end

  return visibility
end

local function make_rule(mode, opts, internal)
  internal = internal or {}
  local visibility = validate_rule(mode, opts, 3)
  local serial = opts.location.algebra.name == 'machine'
  local supplies = mode == 'inspect'
      and {}
      or Algebra.normalise_supply(opts.supply, mode .. ' rule supply', 3)

  return state_spec(opts, {
    serial = serial,
    enumerable = opts.cursor ~= nil,
    eager = internal.eager == true,
    total = internal.total == true,
    order = opts.serial_order or 0,
    accepts_supply = visibility == 'together',
    supplies = supplies,
    writes = mode == 'change',
    ready = internal.probe,
    step = opts.step,
    cursor = opts.cursor,
  }, internal)
end

M.rule = {}

function M.rule.inspect(opts)
  return make_rule('inspect', opts)
end

function M.rule.change(opts)
  return make_rule('change', opts)
end

function M.rule.exchange(opts)
  return Operation.exchange(opts)
end

-- Private compiler entry used by closed façades such as Machine and Clock.
-- The public rule vocabulary does not expose totality, eagerness, probes or
-- ambient absence validation.
function M._state_rule(mode, opts, internal)
  if mode ~= 'inspect' and mode ~= 'change' then
    error('state rule mode must be inspect or change', 2)
  end
  return make_rule(mode, opts, internal)
end

-- Built-in clock waits are the sole ambient absence validator. Ordinary
-- external resources rely on managed-location versions instead.
function M._clock_wait(opts)
  return M.op(M._state_rule('inspect', {
    location = assert(opts.location, 'clock wait requires location'),
    payload = opts.payload,
    resource = opts.resource,
    wake = opts.wake,
    visibility = 'own',
    step = assert(opts.step, 'clock wait requires step'),
  }, {
    absence_check = assert(opts.absence_check, 'clock wait requires absence validation'),
  }))
end

return M

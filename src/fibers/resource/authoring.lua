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


local LOCATION_OPTIONS = {
  algebra = true,
  value = true,
  version = Contract.non_negative_integer,
  clone_value = Contract.func,
  value_equal = Contract.func,
  put_equal = Contract.boolean,
  remove_idempotent = Contract.boolean,
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
  return Journal.new_location(opts, owner)
end

-- Private common constructor for state-backed facilities.
function M._state(resource, value, algebra, semantics, label)
  resource._value_semantics = semantics
  value = semantics.capture(value, label, 4)
  resource._location = M.location(resource, {
    algebra = algebra, value = value, value_equal = semantics.equal,
  })
  return resource
end

-- Private lazy per-key location factory for compound resources.
function M._keyspace(owner, spec)
  local initial, locations = spec.values or {}, {}
  return function(key)
    local location = locations[key]
    if location then return location end
    local value = initial[key]
    initial[key] = nil
    if value == nil and spec.absent then value = spec.absent end
    if spec.clone_initial then value = spec.clone_initial(value) end
    location = M.location(owner, {
      algebra = spec.algebra, value = value,
      clone_value = spec.clone_value, put_equal = spec.put_equal,
      remove_idempotent = spec.remove_idempotent,
    })
    locations[key] = location
    return location
  end
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

M.op = Operation.op
M.bind = Operation.bind

function M.read(location, result, resource)
  return Operation.read(location, result or M.result.value, resource)
end

local function patch_spec(location, result, resource, patch, supply)
  return Operation.patch(location, nil, result or M.result.boolean, resource, patch, supply)
end

function M.replace(location, result, resource)
  return patch_spec(location, result, resource, M.patch.replace, { any = true })
end

function M.add(location, result, resource)
  return patch_spec(location, result, resource, M.patch.add)
end

function M.presence_put(location, result, resource)
  return patch_spec(location, result, resource, M.patch.put, { up = true })
end

function M.version_wait(location, resource)
  return Operation.version_wait(location, nil, resource)
end

M.clock_now = Operation.clock_now

function M.outcome(patch, ...)
  return { patch = patch, result = Values.pack(...) }
end

function M.outcome_packed(patch, packed)
  if not Values.is(packed) then error('packed outcome requires a Fibers value pack', 2) end
  return { patch = patch, result = packed }
end

local function validate_rule(mode, opts, level)
  Contract.options(opts, RULE_OPTIONS, mode .. ' rule options', (level or 2) + 1)
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

  return Operation.transition({
    location = opts.location, orientation = opts.demand, argument = opts.payload,
    resource = opts.resource, interest = opts.wake, absence_check = internal.absence_check,
    name = internal.name,
    transition = {
      serial = serial, enumerable = opts.cursor ~= nil, eager = internal.eager == true,
      total = internal.total == true, order = opts.serial_order or 0,
      accepts_supply = visibility == 'together', supplies = supplies, writes = mode == 'change',
      ready = internal.probe, step = opts.step, cursor = opts.cursor,
    },
  })
end

M.rule = {}

function M.rule.inspect(opts)
  return make_rule('inspect', opts)
end

function M.rule.change(opts)
  return make_rule('change', opts)
end

M.rule.exchange = Operation.exchange

-- Private compiler entry used by closed façades such as Machine and Clock.
-- The public rule vocabulary does not expose totality, eagerness or probes.
M._state_rule = make_rule


return M

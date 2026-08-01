-- Narrow trusted resource-authoring boundary.
--
-- This module owns committed locations, executable primitive specifications and
-- their binding into immutable Ops. Collection helpers and higher-level waiting
-- loops live in separate resource modules.

local Operation = require('fibers.internal.operation')
local Values = require('fibers.internal.values')
local Journal = require('fibers.internal.kernel.journal')
local Algebra = require('fibers.internal.kernel.algebra')

local M = {}

local TRANSITION_OPTIONS = {
  location = true,
  group = true,
  demand = true,
  payload = true,
  resource = true,
  interest = true,
  absence_check = true,
  result = true,
  step = true,
  cursor = true,
  serial = true,
  eager = true,
  total = true,
  order = true,
  accepts_supply = true,
  supplies = true,
  writes = true,
  ready = true,
}

local function validate_keys(value, allowed, label, level)
  if type(value) ~= 'table' then
    error(label .. ' must be a table', level or 3)
  end
  for key in pairs(value) do
    if not allowed[key] then
      error(label .. ' does not accept ' .. tostring(key), level or 3)
    end
  end
end

local ids = {}
function M.kind(name)
  return { name = assert(name, 'facility kind requires a name') }
end

function M.identity(resource, kind, name)
  local prefix = kind.name
  local id = (ids[prefix] or 0) + 1
  ids[prefix] = id
  resource.name = name or (prefix .. '-' .. tostring(id))
  resource._fibers_id = prefix .. '-' .. tostring(id)
  resource._fibers_kind = kind
  return resource
end

function M.location(owner, suffix, opts)
  opts = opts or {}
  opts.owner = opts.owner or owner
  opts.name = opts.name or ((owner and owner.name or 'resource') .. ':' .. tostring(suffix or 'state'))
  return Journal.new_location(opts)
end

M.change = {
  add = function(delta)
    return { kind = 'add', delta = delta }
  end,
  put = function(value)
    return { kind = 'presence', ops = { { op = 'put', value = value } } }
  end,
  remove = function()
    return { kind = 'presence', ops = { { op = 'remove' } } }
  end,
  take = function()
    return { kind = 'presence', ops = { { op = 'take' } } }
  end,
  map_put = function(key, value, policy)
    return { kind = 'finite_map', ops = { { op = 'put', key = key, value = value, policy = policy } } }
  end,
  map_remove = function(key)
    return { kind = 'finite_map', ops = { { op = 'remove', key = key } } }
  end,
}

M.result = Operation.result

function M.op(spec)
  return Operation.op(spec)
end

function M.bind(spec, argument)
  return Operation.bind(spec, argument)
end

function M.read(location, result, resource)
  return Operation.read(location, result or M.result.value, resource)
end

function M.write(location, change, result, resource)
  return Operation.patch(location, change, result or M.result.boolean, resource)
end

function M.replace(location, result, resource)
  return Operation.patch(location, nil, result or M.result.boolean, resource, function(value)
    return { kind = 'replace', value = value }
  end, { any = true })
end

function M.presence_put(location, result, resource)
  return Operation.patch(location, nil, result or M.result.boolean, resource, function(value)
    return { kind = 'presence', ops = { { op = 'put', value = value } } }
  end, { up = true })
end

function M.version_wait(location, resource)
  return Operation.version_wait(location, nil, resource)
end

function M.observe(resource, observation, result)
  return Operation.observe(resource, observation, result or M.result.value)
end

function M.exchange(opts)
  return Operation.exchange(opts)
end

function M.clock_now(resource)
  return Operation.clock_now(resource)
end

local function transition_spec(opts, transition)
  return Operation.transition({
    location = opts.location,
    group = opts.group or opts.location,
    orientation = opts.demand,
    argument = opts.payload,
    resource = opts.resource,
    interest = opts.interest,
    absence_check = opts.absence_check,
    result = opts.result or M.result.value,
    transition = transition,
  })
end

function M.outcome(patch, ...)
  return { patch = patch, writes = patch ~= nil, result = Values.pack(...) }
end

-- A direct trusted transition. step returns nil for present blocking or an
-- outcome record. cursor may be supplied for enumerable alternatives.
function M.transition(opts)
  validate_keys(opts, TRANSITION_OPTIONS, 'transition options', 2)
  assert(opts.location, 'transition requires location')
  assert(
    type(opts.step) == 'function' or type(opts.cursor) == 'function',
    'transition requires step or cursor'
  )
  return transition_spec(opts, {
    serial = opts.serial == true,
    enumerable = opts.cursor ~= nil,
    eager = opts.eager == true,
    total = opts.total == true,
    order = opts.order or 0,
    accepts_supply = opts.accepts_supply == true,
    supplies = Algebra.normalise_supply(opts.supplies or 'none', 'transition supplies', 2),
    writes = opts.writes == true,
    ready = opts.ready,
    step = opts.step,
    cursor = opts.cursor,
  })
end

-- Adapt the public Machine.Wait/Machine.Ready protocol to one executable
-- transition leaf. Both local machines and host-backed waits use this path.
function M.machine_transition(opts, transition)
  local function argument_or_empty(argument)
    return argument == nil and {} or argument
  end
  return M.transition({
    location = assert(opts.location, 'machine transition requires location'),
    payload = opts.payload,
    resource = opts.resource,
    interest = opts.interest,
    absence_check = opts.absence_check,
    serial = transition.serial,
    eager = transition.eager,
    total = transition.total,
    order = transition.order,
    accepts_supply = transition.accepts_supply,
    supplies = transition.supplies,
    writes = transition.writes,
    ready = transition.ready and function(value, argument, context)
      local result = transition.ready(value, argument_or_empty(argument), context)
      return result ~= nil
        and result ~= false
        and not (type(result) == 'table' and result._fibers_cell_wait == true)
    end or nil,
    step = function(value, argument, context)
      local outcome = transition.step(value, argument_or_empty(argument), context)
      if type(outcome) == 'table' and outcome._fibers_cell_wait == true then
        return nil
      end
      if not (type(outcome) == 'table' and outcome._fibers_cell_ready == true) then
        error('machine transition must return Machine.Wait or Machine.Ready', 2)
      end
      if transition.mode == 'query' and outcome.writes then
        error('query transition cannot write', 2)
      end
      return {
        machine = true,
        writes = outcome.writes == true,
        value = outcome.value,
        result = outcome.pack or Values.pack(),
      }
    end,
  })
end

local VERSIONED_RESULT = M.result.project(function(value, leaf)
  return { value = value, version = leaf.location.version }
end)

function M.cell(resource, value, algebra)
  resource._location = M.location(resource, 'value', {
    algebra = algebra or 'replace',
    domain = 'plain',
    value = value,
  })
  resource._read_op = M.op(M.read(resource._location, M.result.value, resource))
  resource._state_op = M.op(M.read(resource._location, VERSIONED_RESULT, resource))
  resource._write_spec = M.replace(resource._location, M.result.boolean, resource)
  resource._changed_spec = M.version_wait(resource._location, resource)
  resource._expect_spec = M.transition({
    location = resource._location,
    resource = resource,
    serial = true,
    writes = false,
    step = function(current, expected)
      if current ~= expected then
        return nil
      end
      return M.outcome(nil, true)
    end,
  })
  return resource
end

function M.publish(location, value)
  location.value = value
  location.version = (location.version or 0) + 1
  return value
end

function M.external_wait(resource, location, transition, opts)
  opts = opts or {}
  return M.op(M.machine_transition({
    location = location,
    payload = opts.payload,
    resource = resource,
    interest = opts.interest,
    absence_check = opts.absence_check,
  }, transition))
end

function M.normalise_supply(value, label, level)
  return Algebra.normalise_supply(value, label, (level or 1) + 1)
end

return M

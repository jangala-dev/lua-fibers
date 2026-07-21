-- Trusted resource-authoring boundary.
--
-- Resource modules describe committed locations, atomic changes, transition
-- rules and result codecs here.  Only this module knows the concrete kernel
-- constructors; facilities do not manipulate ledger or algebra summaries.

local Op = require('fibers.op')
local IR = require('fibers.internal.kernel.ir')
local Ledger = require('fibers.internal.kernel.ledger')
local Algebra = require('fibers.internal.kernel.algebra')
local Supply = require('fibers.internal.kernel.supply')
local perform = require('fibers.perform')

local M = { ABSENT = Algebra.ABSENT }

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
  return Ledger.new_location(opts)
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

M.result = {
  value = { kind = 'value' },
  boolean = { kind = 'constant', value = true },
  present = { kind = 'present' },
  index_entry = { kind = 'index_entry' },
  scalar_snapshot = { kind = 'scalar_snapshot' },
  counter_state = { kind = 'counter_state' },
}
function M.result.presence(nil_sentinel)
  return { kind = 'presence', nil_sentinel = nil_sentinel }
end

function M.read(location, result)
  return IR.read(location, result or M.result.value)
end

function M.write(location, change, result)
  return IR.patch(location, change, result or M.result.boolean)
end

local function action_supplies(location, action)
  if not action then
    return {}
  end
  if action.kind == 'static' then
    return Algebra.supplies(location, action.patch)
  end
  if action.kind == 'take_witness' then
    return { down = true }
  end
  if action.kind == 'put' then
    return { up = true }
  end
  return { any = true }
end

local function claim_rule(opts, eager)
  local action = opts.action or (opts.change and { kind = 'static', patch = opts.change })
  return {
    type = 'claim',
    serial = false,
    enumerable = false,
    eager = eager ~= nil,
    total = false,
    order = opts.order or 0,
    accepts_supply = true,
    supplies = action_supplies(opts.location, action),
    writes = action ~= nil or eager ~= nil,
    query = assert(opts.query, 'claim requires a query'),
    action = action,
    eager_patch = eager,
  }
end

local function transition_program(opts, rule)
  return IR.transition({
    location = opts.location,
    group = opts.group or opts.location,
    orientation = opts.demand,
    payload = opts.payload,
    resource = opts.resource,
    interest = opts.interest,
    absence_check = opts.absence_check,
    result = opts.result or M.result.value,
    rule = rule,
  })
end

function M.claim(opts)
  return transition_program(opts, claim_rule(opts))
end

function M.conditional(opts)
  local query = opts.query or { kind = 'predicate', predicate = opts.predicate }
  local copy = {}
  for key, value in pairs(opts) do
    copy[key] = value
  end
  copy.query = query
  copy.action = { kind = 'static', patch = assert(opts.change, 'conditional change required') }
  return transition_program(
    copy,
    claim_rule(copy, assert(opts.immediate, 'conditional immediate change required'))
  )
end

function M.select(opts)
  local copy = {}
  for key, value in pairs(opts) do
    copy[key] = value
  end
  copy.demand = copy.demand or 'up'
  copy.result = copy.result or M.result.index_entry
  copy.query = {
    kind = 'extreme',
    order = assert(copy.order, 'select requires order'),
    rank_field = copy.rank_field or 'rank',
    seq_field = copy.seq_field or 'seq',
  }
  copy.action = { kind = 'take_witness' }
  return M.claim(copy)
end

function M.admit(opts)
  local copy = {}
  for key, value in pairs(opts) do
    copy[key] = value
  end
  copy.demand = copy.demand or 'down'
  copy.result = copy.result or M.result.boolean
  copy.query = {
    kind = 'compatible_insert',
    key = assert(copy.key, 'admit requires key'),
    value = assert(copy.value, 'admit requires value'),
    compatibility = copy.compatibility,
  }
  copy.action = { kind = 'put', key = copy.key, value = copy.value, policy = 'overwrite' }
  return M.claim(copy)
end

function M.machine(location, transition, payload, resource, extra)
  local opts = {
    location = location,
    transition = transition,
    payload = payload or {},
    resource = resource,
  }
  for key, value in pairs(extra or {}) do
    opts[key] = value
  end
  return transition_program(opts, transition)
end

function M.witness(opts)
  if opts.supply ~= nil then
    error('witness transition no longer accepts supply', 2)
  end
  if type(opts.accepts_supply) ~= 'boolean' then
    error('witness transition requires accepts_supply', 2)
  end
  local rule = {
    type = 'witness',
    serial = false,
    enumerable = true,
    eager = false,
    total = false,
    order = opts.order or 0,
    accepts_supply = opts.accepts_supply,
    supplies = M.normalise_supply(opts.supplies, 'witness transition supplies', 2),
    writes = true,
    cursor_factory = assert(opts.cursor, 'witness transition requires cursor'),
  }
  return transition_program(opts, rule)
end

local OBSERVATIONS = {
  keyed = {
    collect = function(resource, read)
      local entries, keys = {}, {}
      for key in pairs(resource.entries) do
        keys[key] = true
      end
      for key in pairs(resource._locations) do
        keys[key] = true
      end
      for key in pairs(keys) do
        local value = read(resource:_location(key))
        if value ~= M.ABSENT then
          entries[key] = value == resource._nil_sentinel and nil or value
        end
      end
      return { entries = entries, version = resource.version }
    end,
  },
  index = {
    collect = function(resource, read)
      local entries = {}
      for key, entry in pairs(read(resource._location) or {}) do
        entries[key] = { key = entry.key, rank = entry.rank, value = entry.value, seq = entry.seq }
      end
      return { entries = entries, version = resource.version }
    end,
  },
  lease = {
    collect = function(resource, read)
      local holders, subjects = {}, {}
      for subject in pairs(resource.holders or {}) do
        subjects[subject] = true
      end
      for subject in pairs(resource._locations or {}) do
        subjects[subject] = true
      end
      for subject in pairs(subjects) do
        local row = {}
        for owner, mode in pairs(read(resource:_location(subject)) or {}) do
          row[owner] = mode
        end
        holders[subject] = row
      end
      return { holders = holders, version = resource.version }
    end,
  },
}

function M.snapshot(resource, kind)
  return IR.observe(resource, assert(OBSERVATIONS[kind], 'unknown observation topology'), M.result.value)
end

local function descriptor(resource, kind, program)
  program.resource = program.resource or resource
  program.resource_kind = program.resource_kind or kind
  return program
end

function M.op(resource, kind, program, payload)
  return Op._primitive(descriptor(resource, kind, program), payload)
end

function M.static(resource, kind, primitive_kind, fields)
  fields = fields or {}
  fields.kind, fields._fibers_program = primitive_kind, true
  return M.op(resource, kind, fields)
end

function M.descriptor(resource, kind, primitive_kind, fields)
  fields = fields or {}
  fields.kind, fields._fibers_program = primitive_kind, true
  return descriptor(resource, kind, fields)
end

function M.occurrence(value, payload)
  return Op._primitive(value, payload)
end

function M.performing(class, names)
  for i = 1, #names do
    local name = names[i]
    class[name] = function(self, ...)
      return perform(self[name .. '_op'](self, ...))
    end
  end
  return class
end

function M.normalise_supply(value, label, level)
  return Supply.normalise(value, label, (level or 1) + 1)
end
function M.supply_empty(value)
  return Supply.is_empty(value)
end

return M

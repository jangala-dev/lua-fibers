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

local M = { ABSENT = Algebra.ABSENT }

local ids = {}
function M.kind(name)
  return { name = assert(name, 'facility kind requires a name') }
end

function M.child_name(name, suffix)
  return name and name .. ':' .. tostring(suffix) or nil
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
}
function M.result.project(fn)
  return { kind = 'project', project = assert(fn, 'result projection required') }
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
  copy.result = copy.result or M.result.value
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
    payload = payload,
    resource = resource,
  }
  for key, value in pairs(extra or {}) do
    opts[key] = value
  end
  local program = transition_program(opts, transition)
  if payload == nil then
    program.bind = 'payload'
  end
  return program
end

function M.witness(opts)
  local rule = {
    type = 'witness',
    serial = false,
    enumerable = true,
    eager = false,
    total = false,
    order = opts.order or 0,
    accepts_supply = opts.accepts_supply == true,
    supplies = M.normalise_supply(opts.supplies or 'none', 'witness transition supplies', 2),
    writes = true,
    cursor_factory = assert(opts.cursor, 'witness transition requires cursor'),
  }
  return transition_program(opts, rule)
end

local function descriptor(resource, kind, program)
  program.resource = program.resource or resource
  return program
end

function M.op(resource, kind, program, payload)
  local compiled = descriptor(resource, kind, program)
  return Op._primitive(compiled, payload)
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

local VERSIONED_RESULT = M.result.project(function(value, program)
  return { value = value, version = program.location.version }
end)

local CELL_WAIT = { _fibers_cell_wait = true }
local CELL_EXPECT = {
  type = 'machine',
  serial = true,
  enumerable = false,
  eager = false,
  total = false,
  writes = false,
  name = 'cell.expect',
  mode = 'query',
  order = 0,
  accepts_supply = false,
  supplies = {},
  step = function(current, expected)
    if current ~= expected then
      return CELL_WAIT
    end
    return { _fibers_cell_ready = true, writes = false, pack = Op._pack(true) }
  end,
}

function M.cell(resource, kind, value, algebra)
  resource._location = M.location(resource, 'value', {
    algebra = algebra or 'replace',
    domain = 'plain',
    value = value,
  })
  resource._read_op = M.static(resource, kind, 'read', {
    location = resource._location,
    result = M.result.value,
  })
  resource._state_op = M.static(resource, kind, 'read', {
    location = resource._location,
    result = VERSIONED_RESULT,
  })
  resource._write_descriptor = M.descriptor(resource, kind, 'patch', {
    location = resource._location,
    bind = 'replace',
    result = M.result.boolean,
  })
  resource._changed_descriptor = M.descriptor(resource, kind, 'version_wait', {
    location = resource._location,
    bind = 'version',
  })
  resource._expect_descriptor =
    M.descriptor(resource, kind, 'transition', M.machine(resource._location, CELL_EXPECT, nil, resource))
  return resource
end

function M.versioned_select(resource, select)
  local function loop()
    return resource._state_op:and_then(Op.guard(function(state)
      local option, wait = select(state.value)
      if option ~= nil then
        return option
      end
      if wait == false then
        return Op.never()
      end
      return M.occurrence(resource._changed_descriptor, state.version):and_then(Op.guard(loop))
    end))
  end
  return loop()
end

local unpack_ = table.unpack or unpack
local function pack(...)
  return { n = select('#', ...), ... }
end

function M.versioned_match(resource, matcher)
  return M.versioned_select(resource, function(value)
    local result = pack(matcher(value))
    if result[1] then
      return Op.always(unpack_(result, 2, result.n))
    end
  end)
end

function M.versioned_wait_until(resource, predicate)
  return M.versioned_select(resource, function(value)
    if predicate(value) then
      return Op.always(value)
    end
  end)
end

function M.publish(location, value)
  location.value = value
  location.version = (location.version or 0) + 1
  return value
end

function M.external_wait(resource, kind, location, transition, opts)
  opts = opts or {}
  return M.op(
    resource,
    kind,
    M.machine(location, transition, opts.payload, resource, {
      interest = opts.interest,
      absence_check = opts.absence_check,
    })
  )
end

function M.normalise_supply(value, label, level)
  return Supply.normalise(value, label, (level or 1) + 1)
end
function M.supply_empty(value)
  return Supply.is_empty(value)
end

-- Shared lazy per-key storage for trusted resources.
local Keyspace = {}
Keyspace.__index = Keyspace

function Keyspace.new(owner, spec)
  spec = spec or {}
  return setmetatable({
    owner = owner,
    values = spec.values or {},
    versions = spec.versions or {},
    locations = {},
    version = 0,
    algebra = assert(spec.algebra, 'keyspace algebra required'),
    domain = spec.domain,
    absent = spec.absent,
    clone_initial = spec.clone_initial,
    clone_value = spec.clone_value,
    put_equal = spec.put_equal,
    remove_idempotent = spec.remove_idempotent,
    refresh = spec.refresh,
  }, Keyspace)
end

function Keyspace:location(key)
  local location = self.locations[key]
  if location then
    if self.refresh then
      self.refresh(self, key, location)
    end
    return location
  end
  local initial = self.values[key]
  if initial == nil and self.absent then
    initial = self.absent
  end
  if self.clone_initial then
    initial = self.clone_initial(initial)
  end
  location = Ledger.new_location({
    name = self.owner.name .. ':' .. tostring(key),
    algebra = self.algebra,
    domain = self.domain,
    value = initial,
    owner = self.owner,
    key = key,
    clone_value = self.clone_value,
    put_equal = self.put_equal,
    remove_idempotent = self.remove_idempotent,
    apply = function(value, applied)
      if value == self.absent then
        self.values[key] = nil
      else
        self.values[key] = value
      end
      self.versions[key] = applied.version
      self.version = self.version + 1
    end,
  })
  self.locations[key] = location
  return location
end

function Keyspace:keys()
  local keys = {}
  for key in pairs(self.values) do
    keys[key] = true
  end
  for key in pairs(self.locations) do
    keys[key] = true
  end
  return keys
end

function Keyspace:observation(spec)
  spec = spec or {}
  local field = spec.field or 'entries'
  local decode = spec.decode or function(value)
    return value
  end
  local include = spec.include or function()
    return true
  end
  local space = self
  return {
    collect = function(_, read)
      local values = {}
      for key in pairs(space:keys()) do
        local value = read(space:location(key))
        if include(value, key) then
          values[key] = decode(value, key)
        end
      end
      return { [field] = values, version = space.version }
    end,
  }
end

Keyspace.ABSENT = Algebra.ABSENT

M.Keyspace = Keyspace

return M

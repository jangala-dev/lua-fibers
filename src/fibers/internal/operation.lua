-- Immutable operations: graph nodes, executable leaves and conservative shape.
--
-- Shape is advisory only. Exact readiness, absence and validation come from
-- executing leaves and their versioned proofs.

local Values = require('fibers.internal.values')
local Algebra = require('fibers.internal.kernel.algebra')

local Operation = {}
local Op = {}
Op.__index = Op

local leaf_op_cache = setmetatable({}, { __mode = 'kv' })

local function children_have(items, field)
  for i = 1, #(items or {}) do
    if items[i][field] == true then return true end
  end
  return false
end

local function structural_wrap(kind, fields)
  if kind == 'annotated' then return fields.post ~= nil or fields.p.has_wrap == true end
  if kind == 'map' then return fields.p.has_wrap == true end
  if kind == 'and_then' or kind == 'or_else' then return fields.p.has_wrap == true or fields.q.has_wrap == true end
  if kind == 'choice' then return children_have(fields.choices, 'has_wrap') end
  if kind == 'product' then return children_have(fields.lanes, 'has_wrap') end
  return false
end

function Operation.new(kind, fields)
  local value = fields or {}
  value.kind = kind
  value.has_wrap = structural_wrap(kind, value)
  return setmetatable(value, Op)
end

function Operation.is(value)
  return type(value) == 'table' and getmetatable(value) == Op
end

function Operation.bind(spec, ...)
  if not (type(spec) == 'table' and spec._fibers_leaf_spec == true) then
    error('primitive requires a trusted executable leaf specification', 2)
  end
  local n = select('#', ...)
  if n > 1 then error('primitive occurrence accepts at most one argument', 2) end
  if n == 0 and spec.cache ~= false then
    local cached = leaf_op_cache[spec]
    if cached then return cached end
    cached = Operation.new('primitive', { spec = spec, arg = spec.argument })
    leaf_op_cache[spec] = cached
    return cached
  end
  local argument = n == 0 and spec.argument or select(1, ...)
  if n == 1 and spec.bind then argument = spec.bind(argument, spec) end
  return Operation.new('primitive', { spec = spec, arg = argument })
end


Operation.class = Op


function Operation.labels(op)
  if not Operation.is(op) then return nil end
  if op.kind == 'annotated' then return op.labels end
  return nil
end

function Operation.diagnostic_label(op)
  local labels = Operation.labels(op)
  return labels and labels[1] or nil
end

local function copy(fields)
  local out = {}
  for key, value in pairs(fields or {}) do out[key] = value end
  return out
end

local function spec(kind, fields)
  local value = copy(fields)
  value._fibers_leaf_spec = true
  value.kind = kind
  return value
end


local RESULT_VALUE = {}
local RESULT_BOOLEAN = {}

Operation.result = {
  value = RESULT_VALUE,
  boolean = RESULT_BOOLEAN,
}

function Operation.result.project(fn)
  assert(type(fn) == 'function', 'result projection required')
  return fn
end

local function result_fn(value)
  if value == nil then return RESULT_VALUE end
  if value ~= RESULT_VALUE and value ~= RESULT_BOOLEAN then
    assert(type(value) == 'function', 'leaf result must be a function')
  end
  return value
end

function Operation.read(location, result, resource)
  return spec('read', { location = location, result = result_fn(result), resource = resource })
end

function Operation.patch(location, patch, result, resource, bind, supplies)
  return spec('patch', {
    location = location,
    argument = patch,
    result = result_fn(result),
    resource = resource,
    bind = bind,
    supplies = supplies,
  })
end


function Operation.transition(opts)
  assert(opts and opts.location, 'transition requires location')
  assert(type(opts.transition) == 'table', 'transition requires executable behaviour')
  return spec('transition', copy(opts))
end

function Operation.version_wait(location, version, resource)
  return spec('version_wait', { location = location, argument = version, result = Operation.result.value, resource = resource })
end

function Operation.clock_now(resource)
  return spec('clock_now', { resource = resource, result = Operation.result.value, cache = false })
end

function Operation.exchange(opts)
  local fields = copy(opts)
  fields.result = result_fn(fields.result)
  return spec('exchange', fields)
end


function Operation.op(leaf)
  return Operation.bind(leaf)
end

function Operation.leaf_kind(leaf)
  return leaf and leaf.kind
end

function Operation.transition_behaviour(leaf)
  if Operation.leaf_kind(leaf) ~= 'transition' or type(leaf.transition) ~= 'table' then
    error('leaf is not a transition', 2)
  end
  return leaf.transition
end

function Operation.argument(leaf, occurrence)
  if type(occurrence) == 'table' and occurrence.kind == 'primitive' and occurrence.spec == leaf then
    return occurrence.arg
  end
  if occurrence ~= nil then
    return leaf.bind and leaf.bind(occurrence, leaf) or occurrence
  end
  return leaf.argument
end

function Operation.result_pack(leaf, value)
  local result = leaf.result
  if result == RESULT_BOOLEAN then
    return Values.pack(true)
  elseif result == nil or result == RESULT_VALUE then
    return Values.pack(value)
  end
  return Values.pack(result(value, leaf))
end

local function one(value)
  local done = false
  return {
    next = function()
      if done then return nil end
      done = true
      return value
    end,
  }
end

local function none()
  return { next = function() return nil end }
end


function Operation.transition_cursor(leaf, value, context, phase, occurrence)
  local transition = Operation.transition_behaviour(leaf)
  local argument = Operation.argument(leaf, occurrence)
  context, phase = context or {}, phase or 'domain'
  if transition.cursor then
    local cursor = transition.cursor(value, argument, context, phase, leaf)
    assert(type(cursor) == 'table' and type(cursor.next) == 'function', 'transition cursor must return { next = function }')
    if transition.writes then return cursor end
    return {
      next = function()
        local outcome = cursor:next()
        if outcome and outcome.patch ~= nil then
          error('inspect rule cannot stage a patch', 2)
        end
        return outcome
      end,
    }
  end
  if transition.step then
    local outcome = transition.step(value, argument, context, phase, leaf)
    if outcome and not transition.writes and outcome.patch ~= nil then
      error('inspect rule cannot stage a patch', 2)
    end
    return outcome and one(outcome) or none()
  end
  error('transition has neither step nor cursor', 2)
end

function Operation.transition_ready(leaf, value, context, occurrence)
  local transition = Operation.transition_behaviour(leaf)
  local argument = Operation.argument(leaf, occurrence)
  if transition.ready then
    local ready = transition.ready(value, argument, context or {}, leaf)
    return ready ~= nil and ready ~= false
  end
  return Operation.transition_cursor(leaf, value, context, 'probe', occurrence):next() ~= nil
end

function Operation.transition_patch(leaf, outcome, serial)
  local patch = outcome.patch
  if patch and patch.kind == 'machine_value' then
    return Algebra.machine_change(leaf.location, serial, patch.value)
  end
  return patch
end


Operation.SUPPLY_NONE = 0
Operation.SUPPLY_OPAQUE = 1
Operation.SUPPLY_EXACT = 2

local function empty()
  return {
    exchanges = {}, locations = {}, resources = {},
    dynamic = false, external = false,
  }
end

local function mark_location(out, location, fields)
  if not location then return end
  local access = out.locations[location]
  if not access then access = {}; out.locations[location] = access end
  for key, value in pairs(fields or {}) do
    if key == 'supplies' then
      access.supplies = Algebra.merge_supply(access.supplies, value)
    elseif value then
      access[key] = true
    end
  end
end

local function mark_resource(out, resource, fields)
  if not resource then return end
  local access = out.resources[resource]
  if not access then access = {}; out.resources[resource] = access end
  for key, value in pairs(fields or {}) do if value then access[key] = true end end
end

local function merge(dst, src)
  if not src then return dst end
  dst.dynamic = dst.dynamic or src.dynamic
  dst.external = dst.external or src.external
  for resource, roles in pairs(src.exchanges or {}) do
    local target = dst.exchanges[resource]
    if not target then target = {}; dst.exchanges[resource] = target end
    for role in pairs(roles) do target[role] = true end
  end
  for location, access in pairs(src.locations or {}) do mark_location(dst, location, access) end
  for resource, access in pairs(src.resources or {}) do mark_resource(dst, resource, access) end
  return dst
end

local function leaf_shape(op, out)
  local leaf = op.spec
  local kind = Operation.leaf_kind(leaf)
  if kind == 'exchange' then
    local roles = out.exchanges[leaf.resource]
    if not roles then roles = {}; out.exchanges[leaf.resource] = roles end
    roles[leaf.role] = true
    return
  end
  local location = leaf.location
  if not location then return end
  if kind == 'read' then
    mark_location(out, location, { read = true })
  elseif kind == 'patch' then
    local supplies = leaf.supplies
    if not supplies then
      local patch = op.arg
      supplies = patch and Algebra.supplies(location, patch) or {}
    end
    mark_location(out, location, { read = true, write = true, supplies = supplies })
  elseif kind == 'version_wait' then
    mark_location(out, location, { read = true, wait = true })
    out.external = true
  elseif kind == 'transition' then
    local transition = Operation.transition_behaviour(leaf)
    mark_location(out, location, {
      read = true,
      write = transition.writes,
      wait = true,
      supplies = transition.supplies,
    })
  else
    error('unknown trusted leaf kind ' .. tostring(kind), 0)
  end
  if leaf.interest ~= nil or leaf.absence_check ~= nil then out.external = true end
end

local describe
local function describe_mode(op, seen, mode)
  if not op then return empty() end
  -- Most primitive shape belongs to the shared executable leaf. A patch
  -- without an explicit supply summary is the exception: its occurrence
  -- argument determines what it may supply, so that shape must remain
  -- occurrence-specific.
  local cache_key = op
  if op.kind == 'primitive' then
    local leaf = op.spec
    if not (Operation.leaf_kind(leaf) == 'patch' and leaf.supplies == nil) then
      cache_key = leaf
    end
  end
  local cache_field = '_fibers_shape_' .. mode
  local cached = rawget(cache_key, cache_field)
  if cached then return cached end
  seen = seen or {}
  if seen[op] then
    local recursive = empty(); recursive.dynamic = true; return recursive
  end
  seen[op] = true
  local out = empty()
  local kind = op.kind
  if kind == 'primitive' then
    leaf_shape(op, out)
  elseif kind == 'choice' then
    for i = 1, #(op.choices or {}) do merge(out, describe_mode(op.choices[i], seen, mode)) end
  elseif kind == 'product' then
    for i = 1, #(op.lanes or {}) do merge(out, describe_mode(op.lanes[i], seen, mode)) end
  elseif kind == 'or_else' then
    merge(out, describe_mode(op.p, seen, mode))
    if mode ~= 'preferred' then merge(out, describe_mode(op.q, seen, mode)) end
  elseif kind == 'annotated' or kind == 'map' then
    merge(out, describe_mode(op.p, seen, mode))
  elseif kind == 'guard' then
    out.dynamic = true
  elseif kind == 'and_then' then
    merge(out, describe_mode(op.p, seen, mode))
    if mode ~= 'active' then merge(out, describe_mode(op.q, seen, mode)) end
  end
  seen[op] = nil
  rawset(cache_key, cache_field, out)
  return out
end

describe = function(op) return describe_mode(op, {}, 'full') end

function Operation.shape(op)
  local shape = describe(op)
  if shape.active == nil then shape.active = describe_mode(op, {}, 'active') end
  return shape
end
function Operation.active_shape(value)
  if value and value.kind then return describe_mode(value, {}, 'active') end
  return value and value.active or value
end
function Operation.active_dynamic(value)
  local active = Operation.active_shape(value)
  return active and active.dynamic == true
end

local function opposite(role)
  if role == 'put' then return 'get' end
  if role == 'get' then return 'put' end
end

function Operation.supply_relation(shape, intent)
  shape = shape or empty()
  if Operation.active_dynamic(shape) then return Operation.SUPPLY_OPAQUE, 'dynamic' end
  if not intent then return Operation.SUPPLY_NONE end
  if intent.kind == 'exchange' then
    local roles, role = shape.exchanges[intent.resource], opposite(intent.role)
    if roles and role and roles[role] then return Operation.SUPPLY_EXACT, 'exchange' end
    return Operation.SUPPLY_NONE
  end
  local leaf = intent.spec
  local location = leaf and leaf.location
  local access = location and shape.locations[location]
  local demand = leaf and leaf.orientation
  if access and Algebra.may_supply(access.supplies, demand) then
    return Operation.SUPPLY_EXACT, 'location', demand
  end
  return Operation.SUPPLY_NONE
end

function Operation.may_supply(shape, intent)
  local relation, reason = Operation.supply_relation(shape, intent)
  if relation == Operation.SUPPLY_OPAQUE then return true, reason end
  return relation == Operation.SUPPLY_EXACT, reason or 'none'
end


function Operation.supply_score(shape, intents)
  if Operation.active_dynamic(shape) then
    return math.max(1, #(intents or {})), Operation.SUPPLY_OPAQUE, 'dynamic'
  end
  local score, reason = 0, nil
  for i = 1, #(intents or {}) do
    local ok, why = Operation.may_supply(shape, intents[i])
    if ok then score = score + 1; reason = reason or why end
  end
  if score == 0 then return 0, Operation.SUPPLY_NONE, 'none' end
  return score, Operation.SUPPLY_EXACT, reason
end


return Operation

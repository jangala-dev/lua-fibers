-- Data-only primitive programmes for the transactional substrate.
--
-- Facility APIs compile to these records.  The runtime owns their meaning;
-- facility modules cannot redefine search, projection, exhaustion, validation
-- or commit.  This module also compiles immutable operation graphs into cached
-- dependency metadata used by recruitment, component isolation and diagnostics.

local M = {}

local function programme(kind, fields)
  fields = fields or {}
  fields._fibers_program = true
  fields.kind = kind
  return fields
end

function M.read(location, result_kind, opts)
  opts = opts or {}
  opts.location = location
  opts.result_kind = result_kind or 'identity'
  return programme('read', opts)
end

function M.patch(location, patch, result_kind, result_value)
  return programme('patch', {
    location = location,
    patch = patch,
    result_kind = result_kind or 'constant',
    result_value = result_value,
  })
end

function M.claim(opts)
  assert(opts and opts.location, 'claim requires location')
  if not opts.query then
    assert(opts.predicate, 'claim requires predicate or query')
    opts.query = {
      kind = 'predicate',
      predicate = opts.predicate,
      threshold = opts.threshold,
      key = opts.key,
    }
  end
  if not opts.transition and opts.patch then
    opts.transition = { kind = 'static', patch = opts.patch }
  end
  return programme('claim', opts)
end

function M.conditional_claim(opts)
  assert(opts and opts.location, 'conditional claim requires location')
  assert(opts.predicate, 'conditional claim requires predicate')
  assert(opts.immediate_patch, 'conditional claim requires immediate patch')
  assert(opts.claim_patch, 'conditional claim requires claim patch')
  return programme('conditional_claim', opts)
end

function M.select(opts)
  assert(opts and opts.location, 'select requires location')
  assert(opts.order == 'min' or opts.order == 'max', 'select requires min or max order')
  opts.orientation = opts.orientation or 'up'
  opts.query = {
    kind = 'extreme',
    order = opts.order,
    rank_field = opts.rank_field or 'rank',
    seq_field = opts.seq_field or 'seq',
  }
  opts.transition = { kind = 'take_witness' }
  return programme('claim', opts)
end

function M.admit(opts)
  assert(opts and opts.location, 'admit requires location')
  assert(opts.key ~= nil, 'admit requires key')
  assert(opts.value ~= nil, 'admit requires value')
  opts.orientation = opts.orientation or 'down'
  opts.query = {
    kind = 'compatible_insert',
    key = opts.key,
    value = opts.value,
    compatibility = opts.compatibility,
  }
  opts.transition = {
    kind = 'put',
    key = opts.key,
    value = opts.value,
    policy = 'overwrite',
  }
  return programme('claim', opts)
end

function M.snapshot(resource, snapshot_kind)
  return programme('snapshot', { resource = resource, snapshot_kind = snapshot_kind })
end

function M.machine_transition(opts)
  assert(opts and opts.location, 'machine transition requires location')
  assert(opts.transition, 'machine transition requires transition')
  opts.order = opts.transition.order or opts.order or 0
  return programme('machine_transition', opts)
end

function M.witness_transition(opts)
  assert(opts and opts.location, 'witness transition requires location')
  assert(
    type(opts.cursor) == 'function' or type(opts.enumerate) == 'function',
    'witness transition requires cursor or enumerate'
  )
  opts.order = opts.order or 0
  return programme('witness_transition', opts)
end

function M.version_wait(location, version)
  return programme('version_wait', { location = location, version = version })
end

function M.exchange(resource, role, value)
  return programme('exchange', { resource = resource, role = role, value = value })
end

function M.open_witness_cursor(program, state, payload, context)
  if type(program.cursor) == 'function' then
    local cursor = program.cursor(state, payload or {}, context or {})
    assert(
      type(cursor) == 'table' and type(cursor.next) == 'function',
      'witness cursor factory must return { next = function }'
    )
    return cursor
  end
  local values = program.enumerate(state, payload or {}, context or {}) or {}
  local i = 0
  return {
    next = function()
      i = i + 1
      return values[i]
    end,
  }
end

function M.witness_ready(program, state, payload, context)
  return M.open_witness_cursor(program, state, payload, context):next() ~= nil
end

-- Cached operation metadata -------------------------------------------------

local metadata_cache = setmetatable({}, { __mode = 'k' })
local dependency_hint_cache = setmetatable({}, { __mode = 'k' })

local function empty_metadata()
  return {
    exchanges = {},
    locations = {},
    resources = {},
    node_kinds = {},
    nodes = 0,
    dynamic = false,
    external = false,
  }
end

local function mark_location(out, loc, fields)
  if not loc then
    return
  end
  local access = out.locations[loc]
  if not access then
    access = {}
    out.locations[loc] = access
  end
  for key, value in pairs(fields or {}) do
    if value then
      access[key] = true
    end
  end
end

local function mark_resource(out, resource, fields)
  if not resource then
    return
  end
  local access = out.resources[resource]
  if not access then
    access = {}
    out.resources[resource] = access
  end
  for key, value in pairs(fields or {}) do
    if value then
      access[key] = true
    end
  end
end

local function metadata_merge(dst, src)
  if not src then
    return dst
  end
  dst.dynamic = dst.dynamic or src.dynamic
  dst.external = dst.external or src.external
  dst.nodes = (dst.nodes or 0) + (src.nodes or 0)
  for kind, count in pairs(src.node_kinds or {}) do
    dst.node_kinds[kind] = (dst.node_kinds[kind] or 0) + count
  end
  for resource, roles in pairs(src.exchanges or {}) do
    local target = dst.exchanges[resource]
    if not target then
      target = {}
      dst.exchanges[resource] = target
    end
    for role in pairs(roles) do
      target[role] = true
    end
  end
  for loc, access in pairs(src.locations or {}) do
    mark_location(dst, loc, access)
  end
  for resource, access in pairs(src.resources or {}) do
    mark_resource(dst, resource, access)
  end
  return dst
end

local function primitive_metadata(op, out)
  local p = op.program
  local kind = p.program_kind or p.kind
  if kind == 'exchange' then
    local roles = out.exchanges[p.resource]
    if not roles then
      roles = {}
      out.exchanges[p.resource] = roles
    end
    roles[p.role] = true
    return
  end
  if kind == 'snapshot' then
    mark_resource(out, p.resource or op.resource, { observe = true })
    return
  end
  if not p.location then
    return
  end

  if kind == 'read' then
    mark_location(out, p.location, { read = true })
  elseif kind == 'patch' then
    mark_location(out, p.location, { read = true, write = true, supply = true })
  elseif kind == 'version_wait' then
    mark_location(out, p.location, { read = true, wait = true })
    out.external = true
  elseif kind == 'claim' or kind == 'conditional_claim' then
    mark_location(out, p.location, { read = true, write = true, wait = true, supply = true })
  elseif kind == 'machine_transition' then
    local supply = p.transition and p.transition.supply or 'interacting'
    mark_location(out, p.location, {
      read = true,
      write = p.transition and p.transition.mode ~= 'query',
      wait = true,
      supply = supply ~= 'none',
    })
  elseif kind == 'witness_transition' then
    mark_location(out, p.location, {
      read = true,
      write = true,
      wait = true,
      supply = (p.supply or 'interacting') ~= 'none',
    })
  else
    mark_location(out, p.location, { read = true, write = true, supply = true })
  end
  if p.interest ~= nil or p.absence_check ~= nil then
    out.external = true
  end
end

local describe

local function metadata_from_hint(hint, seen)
  if hint == false then
    return empty_metadata()
  end
  if type(hint) ~= 'table' then
    local out = empty_metadata()
    out.dynamic = true
    return out
  end
  if hint.kind and hint._id then
    return describe(hint, seen)
  end
  if hint._fibers_dependencies then
    local cached = dependency_hint_cache[hint]
    if cached then
      return cached
    end
    local out = empty_metadata()
    for i = 1, #(hint.parts or {}) do
      metadata_merge(out, metadata_from_hint(hint.parts[i], seen))
    end
    dependency_hint_cache[hint] = out
    return out
  end
  if hint.footprint ~= nil then
    return metadata_from_hint(hint.footprint, seen)
  end
  if hint.continuation ~= nil then
    return metadata_from_hint(hint.continuation, seen)
  end

  local out = empty_metadata()
  out.dynamic = hint.dynamic == true
  out.external = hint.external == true
  for resource, roles in pairs(hint.exchanges or {}) do
    local target = {}
    out.exchanges[resource] = target
    for role, present in pairs(roles) do
      if present then
        target[role] = true
      end
    end
  end
  for loc, access in pairs(hint.locations or {}) do
    if access == true then
      mark_location(out, loc, { read = true, write = true, supply = true })
    else
      mark_location(out, loc, access)
    end
  end
  for resource, access in pairs(hint.resources or {}) do
    if access == true then
      mark_resource(out, resource, { observe = true })
    else
      mark_resource(out, resource, access)
    end
  end
  return out
end

describe = function(op, seen)
  if not op then
    return empty_metadata()
  end
  local cache_key = op.program and op.program._fibers_compact_descriptor and op.program or op
  local cached = metadata_cache[cache_key]
  if cached then
    return cached
  end
  seen = seen or {}
  if seen[op] then
    local recursive = empty_metadata()
    recursive.dynamic = true
    return recursive
  end
  seen[op] = true

  local out = empty_metadata()
  out.nodes = 1
  out.node_kinds[op.kind or 'unknown'] = 1
  local kind = op.kind
  if kind == 'primitive' then
    primitive_metadata(op, out)
  elseif kind == 'choice' then
    for i = 1, #(op.choices or {}) do
      metadata_merge(out, describe(op.choices[i], seen))
    end
  elseif kind == 'product' then
    for i = 1, #(op.lanes or {}) do
      metadata_merge(out, describe(op.lanes[i], seen))
    end
  elseif kind == 'or_else' then
    metadata_merge(out, describe(op.p, seen))
    metadata_merge(out, describe(op.q, seen))
  elseif kind == 'annotated' then
    metadata_merge(out, describe(op.p, seen))
  elseif kind == 'and_then' then
    metadata_merge(out, describe(op.p, seen))
    if not op.derived_map then
      if op.continuation_footprint ~= nil then
        metadata_merge(out, metadata_from_hint(op.continuation_footprint, seen))
      else
        out.dynamic = true
      end
    end
  end

  seen[op] = nil
  out.analysable = not out.dynamic
  metadata_cache[cache_key] = out
  return out
end

function M.metadata_hint(hint)
  return metadata_from_hint(hint, {})
end

function M.metadata_covers(declared, actual)
  declared, actual = declared or empty_metadata(), actual or empty_metadata()
  if declared.dynamic then
    return true
  end
  if actual.dynamic then
    return false, 'dynamic continuation'
  end
  if actual.external and not declared.external then
    return false, 'external dependency'
  end
  for resource, roles in pairs(actual.exchanges or {}) do
    local allowed = declared.exchanges and declared.exchanges[resource]
    if not allowed then
      return false, 'exchange resource ' .. tostring(resource)
    end
    for role in pairs(roles) do
      if not allowed[role] then
        return false, 'exchange role ' .. tostring(role)
      end
    end
  end
  for location, access in pairs(actual.locations or {}) do
    local allowed = declared.locations and declared.locations[location]
    if not allowed then
      return false, 'location ' .. tostring(location)
    end
    for mode, present in pairs(access) do
      if present and not allowed[mode] then
        return false, 'location mode ' .. tostring(mode)
      end
    end
  end
  for resource, access in pairs(actual.resources or {}) do
    local allowed = declared.resources and declared.resources[resource]
    if not allowed then
      return false, 'resource ' .. tostring(resource)
    end
    for mode, present in pairs(access) do
      if present and not allowed[mode] then
        return false, 'resource mode ' .. tostring(mode)
      end
    end
  end
  return true
end

function M.metadata(op)
  return describe(op)
end
function M.footprint(op)
  return describe(op)
end

local function opposite_role(role)
  if role == 'put' then
    return 'get'
  end
  if role == 'get' then
    return 'put'
  end
  return nil
end

function M.metadata_may_supply(metadata, intent)
  metadata = metadata or empty_metadata()
  if metadata.dynamic then
    return true, 'dynamic'
  end
  if not intent then
    return false, 'none'
  end
  if intent.kind == 'exchange' then
    local roles = metadata.exchanges[intent.resource]
    local opposite = opposite_role(intent.role)
    if roles and opposite and roles[opposite] then
      return true, 'exchange'
    end
    return false, 'none'
  end
  local loc = intent.program and (intent.program.location or intent.program.group)
  local access = loc and metadata.locations[loc]
  if access and access.supply then
    return true, 'location'
  end
  return false, 'none'
end

function M.footprint_may_supply(metadata, intents)
  if metadata and metadata.dynamic then
    return true, 'dynamic'
  end
  for i = 1, #(intents or {}) do
    local ok, reason = M.metadata_may_supply(metadata, intents[i])
    if ok then
      return true, reason
    end
  end
  return false, 'none'
end

function M.supply_score(metadata, intents)
  local score, first_reason = 0, nil
  if metadata and metadata.dynamic then
    return math.max(1, #(intents or {})), 'dynamic'
  end
  for i = 1, #(intents or {}) do
    local ok, reason = M.metadata_may_supply(metadata, intents[i])
    if ok then
      score = score + 1
      first_reason = first_reason or reason
    end
  end
  return score, first_reason or 'none'
end

function M.metadata_counts(metadata)
  local exchanges, locations, resources = 0, 0, 0
  for _ in pairs((metadata and metadata.exchanges) or {}) do
    exchanges = exchanges + 1
  end
  for _ in pairs((metadata and metadata.locations) or {}) do
    locations = locations + 1
  end
  for _ in pairs((metadata and metadata.resources) or {}) do
    resources = resources + 1
  end
  return exchanges, locations, resources
end

return M

-- Data-only primitive programmes for the transactional substrate.
--
-- Facility APIs compile to these records.  The runtime owns their meaning;
-- facility modules cannot redefine search, projection, exhaustion, validation
-- or commit.  This module also compiles immutable option graphs into cached
-- dependency metadata used by recruitment, component isolation and diagnostics.

local Op = require('fibers.op')
local Supply = require('fibers.internal.kernel.supply')
local Algebra = require('fibers.internal.kernel.algebra')

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

local function transition_program(opts, rule)
  opts.rule = rule
  return programme('transition', opts)
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

local function claim_rule(opts, eager_patch)
  local query = opts.query
  if not query then
    assert(opts.predicate, 'claim requires predicate or query')
    query = {
      kind = 'predicate',
      predicate = opts.predicate,
      threshold = opts.threshold,
      key = opts.key,
    }
  end
  local action = opts.transition
  if not action and opts.patch then
    action = { kind = 'static', patch = opts.patch }
  end
  return {
    type = 'claim',
    serial = false,
    enumerable = false,
    eager = eager_patch ~= nil,
    total = false,
    order = opts.order or 0,
    accepts_supply = true,
    supplies = action_supplies(opts.location, action),
    writes = action ~= nil or eager_patch ~= nil,
    query = query,
    action = action,
    eager_patch = eager_patch,
  }
end

function M.claim(opts)
  assert(opts and opts.location, 'claim requires location')
  local rule = claim_rule(opts)
  opts.query, opts.transition, opts.patch = nil, nil, nil
  return transition_program(opts, rule)
end

function M.conditional_claim(opts)
  assert(opts and opts.location, 'conditional claim requires location')
  assert(opts.predicate, 'conditional claim requires predicate')
  assert(opts.immediate_patch, 'conditional claim requires immediate patch')
  assert(opts.claim_patch, 'conditional claim requires claim patch')
  opts.query = {
    kind = 'predicate',
    predicate = opts.predicate,
    threshold = opts.threshold,
    key = opts.key,
  }
  opts.transition = { kind = 'static', patch = opts.claim_patch }
  local rule = claim_rule(opts, opts.immediate_patch)
  opts.predicate, opts.threshold, opts.key = nil, nil, nil
  opts.query, opts.transition, opts.immediate_patch, opts.claim_patch = nil, nil, nil, nil
  return transition_program(opts, rule)
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
  return M.claim(opts)
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
  return M.claim(opts)
end

function M.snapshot(resource, snapshot_kind)
  return programme('snapshot', { resource = resource, snapshot_kind = snapshot_kind })
end

function M.machine_transition(opts)
  assert(opts and opts.location, 'machine transition requires location')
  local transition = assert(opts.transition, 'machine transition requires transition')
  assert(transition.supply == nil, 'machine transition no longer accepts supply')
  assert(type(transition.accepts_supply) == 'boolean', 'machine transition requires accepts_supply')
  transition.supplies = Supply.normalise(transition.supplies, 'machine transition supplies', 2)
  local rule = {
    type = 'machine',
    serial = true,
    enumerable = false,
    eager = false,
    total = transition.mode == 'update',
    order = transition.order or opts.order or 0,
    accepts_supply = transition.accepts_supply,
    supplies = transition.supplies,
    writes = transition.mode ~= 'query',
    transition = transition,
  }
  opts.transition, opts.order = nil, nil
  return transition_program(opts, rule)
end

function M.witness_transition(opts)
  assert(opts and opts.location, 'witness transition requires location')
  assert(opts.supply == nil, 'witness transition no longer accepts supply')
  assert(type(opts.cursor) == 'function', 'witness transition requires cursor')
  assert(type(opts.accepts_supply) == 'boolean', 'witness transition requires accepts_supply')
  local rule = {
    type = 'witness',
    serial = false,
    enumerable = true,
    eager = false,
    total = false,
    order = opts.order or 0,
    accepts_supply = opts.accepts_supply,
    supplies = Supply.normalise(opts.supplies, 'witness transition supplies', 2),
    writes = true,
    cursor_factory = opts.cursor,
  }
  opts.cursor, opts.accepts_supply, opts.supplies, opts.order = nil, nil, nil, nil
  return transition_program(opts, rule)
end

function M.version_wait(location, version)
  return programme('version_wait', { location = location, version = version })
end

function M.exchange(resource, role, value)
  return programme('exchange', { resource = resource, role = role, value = value })
end

-- Cached option metadata -------------------------------------------------

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
    if key == 'supply' or key == 'supply_up' or key == 'supply_down' or key == 'supply_any' then
      error('legacy location supply metadata is not supported; use supplies', 0)
    elseif key == 'supplies' then
      access.supplies = Supply.merge_into(access.supplies, value)
    elseif value then
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

local function mark_patch_supply(access, location, patch)
  access.supplies = Supply.merge_into(access.supplies, Algebra.supplies(location, patch))
end

local function primitive_supply_access(program)
  local access = { read = true, write = true, supplies = {} }
  mark_patch_supply(access, program.location, program.patch)
  if program.payload_patch == 'replace' then
    access.supplies.any = true
  end
  return access
end

local function primitive_metadata(op, out)
  local p = op.program
  local kind = M.kind(p)
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
    mark_location(out, p.location, primitive_supply_access(p))
  elseif kind == 'version_wait' then
    mark_location(out, p.location, { read = true, wait = true })
    out.external = true
  elseif kind == 'transition' then
    local rule = M.rule(p)
    mark_location(out, p.location, {
      read = true,
      write = rule.writes,
      wait = true,
      supplies = rule.supplies,
    })
  else
    error('unknown trusted primitive programme kind ' .. tostring(kind), 0)
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
      error('location dependency hints must declare read/write/wait and supplies explicitly', 0)
    end
    local fields = {}
    for key, value in pairs(access or {}) do
      if key == 'supplies' then
        fields.supplies = Supply.normalise(value, 'location dependency supplies', 2)
      else
        fields[key] = value
      end
    end
    mark_location(out, loc, fields)
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
      return false, 'location ' .. tostring(location.name or location._fibers_id or location)
    end
    for mode, present in pairs(access) do
      if mode == 'supplies' then
        for direction in pairs(present or {}) do
          local allowed_supplies = allowed.supplies
          if not (allowed_supplies and (allowed_supplies.any or allowed_supplies[direction])) then
            return false,
              'location supply direction ' .. tostring(direction) .. ' at ' .. tostring(
                location.name or location._fibers_id or location
              )
          end
        end
      elseif present and not allowed[mode] then
        return false,
          'location mode ' .. tostring(mode) .. ' at ' .. tostring(
            location.name or location._fibers_id or location
          )
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
  local program = intent.program
  local loc = program and (program.location or program.group)
  local access = loc and metadata.locations[loc]
  local demand = program and (program.orientation or program.demand_tag)
  if access and Supply.may_supply(access.supplies, demand) then
    return true, demand and ('location-' .. tostring(demand)) or 'location-any-demand'
  end
  return false, 'none'
end

function M.metadata_may_supply_any(metadata, intents)
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

-- Canonical transition rules ---------------------------------------------

local function one(value)
  local done = false
  return {
    next = function()
      if done then
        return nil
      end
      done = true
      return value
    end,
  }
end

local function none()
  return {
    next = function()
      return nil
    end,
  }
end

local function is_wait(value)
  return type(value) == 'table' and value._fibers_scalar_wait == true
end

local function is_ready(value)
  return type(value) == 'table' and value._fibers_scalar_ready == true
end

local function machine_outcome(program, value, context)
  local transition, payload = M.rule(program).transition, program.payload or {}
  local packed = Op._pack(transition.step(value, payload, context))
  local first = packed[1]
  if packed.n == 1 and is_wait(first) then
    return nil
  end
  if is_ready(first) then
    if transition.mode == 'query' and first.writes then
      return nil
    end
    return {
      machine = true,
      writes = first.writes == true,
      value = first.value,
      result = first.pack or Op._pack(),
    }
  end
  if transition.mode == 'update' then
    if packed.n == 0 then
      return nil
    end
    local result = { n = packed.n - 1, _fibers_pack = true }
    for i = 2, packed.n do
      result[i - 1] = packed[i]
    end
    return { machine = true, writes = true, value = packed[1], result = result }
  end
  if packed.n == 0 or packed[1] == nil then
    return nil
  end
  if transition.mode == 'select' then
    local result = { n = packed.n - 1, _fibers_pack = true }
    for i = 2, packed.n do
      result[i - 1] = packed[i]
    end
    return { machine = true, writes = true, value = packed[1], result = result }
  end
  return { machine = true, writes = false, result = packed }
end

local pack = Op._pack
function M.result_pack(program, value, session)
  local result = session and function(...)
    return session:pack(...)
  end or pack
  local kind = program.result_kind or 'constant'
  if kind == 'constant' then
    return result(program.result_value)
  end
  if kind == 'identity' or kind == 'map_value' then
    return result(value)
  end
  if kind == 'presence_bool' then
    return result(value ~= Algebra.ABSENT)
  end
  if kind == 'presence_value' then
    if value == Algebra.ABSENT or (program.nil_sentinel and value == program.nil_sentinel) then
      return result(nil)
    end
    return result(value)
  end
  if kind == 'index_entry' then
    return result(value and { key = value.key, rank = value.rank, value = value.value, seq = value.seq })
  end
  if kind == 'scalar_snapshot' then
    return result({ value = value, version = program.location.version })
  end
  if kind == 'counter_state' then
    local owner = program.owner
    return result({ value = value, min = owner.min, max = owner.max, version = program.location.version })
  end
  error('unknown programme result kind: ' .. tostring(kind), 2)
end

function M.predicate_holds(program, value)
  local predicate = program.predicate
  if predicate == 'present' then
    return value ~= Algebra.ABSENT
  end
  if predicate == 'absent' then
    return value == Algebra.ABSENT
  end
  if predicate == 'ge' then
    return value >= program.threshold
  end
  if predicate == 'map_present' then
    return value[program.key] ~= nil
  end
  if predicate == 'map_absent' then
    return value[program.key] == nil
  end
  error('unknown claim predicate: ' .. tostring(predicate), 2)
end

local function select_extreme(query, value)
  local best, rank_field, seq_field = nil, query.rank_field or 'rank', query.seq_field or 'seq'
  local maximum = query.order == 'max'
  for key, entry in pairs(value or {}) do
    if not best then
      best = { key = key, entry = entry }
    else
      local rank, best_rank = entry[rank_field], best.entry[rank_field]
      local better
      if rank ~= best_rank then
        better = maximum and rank > best_rank or not maximum and rank < best_rank
      else
        local seq, best_seq = entry[seq_field] or 0, best.entry[seq_field] or 0
        if seq ~= best_seq then
          better = maximum and seq > best_seq or not maximum and seq < best_seq
        else
          local text, best_text = tostring(key), tostring(best.key)
          better = maximum and text > best_text or not maximum and text < best_text
        end
      end
      if better then
        best = { key = key, entry = entry }
      end
    end
  end
  return best
end

local function compatible(matrix, left, right)
  return left == right or matrix and matrix[left] and matrix[left][right] == true
end

function M.evaluate_claim(program, value)
  local rule = M.rule(program)
  local query = rule.query
  if not query then
    error('transition rule is missing query', 2)
  end
  local witness = value
  if query.kind == 'predicate' then
    if not M.predicate_holds(query, value) then
      return nil
    end
  elseif query.kind == 'extreme' then
    witness = select_extreme(query, value)
    if not witness then
      return nil
    end
  elseif query.kind == 'compatible_insert' then
    for owner, mode in pairs(value or {}) do
      if
        owner ~= query.key
        and not (
          compatible(query.compatibility, query.value, mode)
          and compatible(query.compatibility, mode, query.value)
        )
      then
        return nil
      end
    end
  else
    error('unknown transition query: ' .. tostring(query.kind), 2)
  end
  local action, patch = rule.action, nil
  if action then
    if action.kind == 'static' then
      patch = action.patch
    elseif action.kind == 'take_witness' then
      patch = { kind = 'finite_map', ops = { { op = 'take', key = witness.key } } }
    elseif action.kind == 'put' then
      patch = {
        kind = 'finite_map',
        ops = {
          {
            op = 'put',
            key = action.key,
            value = action.value,
            policy = action.policy,
          },
        },
      }
    else
      error('unknown transition action: ' .. tostring(action.kind), 2)
    end
  end
  local result = query.kind == 'extreme' and witness.entry or witness
  return { patch = patch, result = M.result_pack(program, result) }
end

function M.kind(program)
  return program and (program.primitive_kind or program.kind)
end

function M.rule(program)
  if M.kind(program) ~= 'transition' or type(program.rule) ~= 'table' then
    error('programme is not a transition rule', 2)
  end
  return program.rule
end

local function witness_cursor(program, rule, value, context)
  local source = rule.cursor_factory(value, program.payload or {}, context)
  assert(
    type(source) == 'table' and type(source.next) == 'function',
    'witness cursor factory must return { next = function }'
  )
  return {
    next = function()
      local outcome = source:next()
      if outcome == nil then
        return nil
      end
      return {
        machine = true,
        writes = outcome.writes ~= false,
        value = outcome.value,
        result = outcome.result,
      }
    end,
  }
end

function M.transition_cursor(program, value, context, phase)
  local rule = M.rule(program)
  context, phase = context or {}, phase or 'domain'
  if rule.type == 'claim' then
    if phase == 'eager' then
      if not rule.eager_patch or not M.predicate_holds(rule.query, value) then
        return none()
      end
      return one({ patch = rule.eager_patch, writes = true, result = M.result_pack(program, value) })
    end
    local outcome = M.evaluate_claim(program, value)
    return outcome and one({ patch = outcome.patch, writes = outcome.patch ~= nil, result = outcome.result })
      or none()
  elseif rule.type == 'machine' then
    local outcome = machine_outcome(program, value, context)
    return outcome and one(outcome) or none()
  elseif rule.type == 'witness' then
    return witness_cursor(program, rule, value, context)
  end
  error('unknown transition rule type ' .. tostring(rule.type), 2)
end

function M.transition_ready(program, value, context)
  local rule = M.rule(program)
  if rule.type == 'machine' and type(rule.transition.ready) == 'function' then
    local result = rule.transition.ready(value, program.payload or {}, context or {})
    return result ~= nil and result ~= false and not is_wait(result)
  end
  return M.transition_cursor(program, value, context, 'probe'):next() ~= nil
end

function M.transition_patch(program, outcome, serial)
  if outcome.patch then
    return outcome.patch
  end
  if outcome.writes and outcome.machine then
    return Algebra.machine_change(program.location, serial, outcome.value)
  end
end

return M

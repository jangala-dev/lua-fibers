-- Data-only primitive programmes for the transactional substrate.
--
-- Facility APIs compile to these records.  The runtime owns their meaning;
-- facility modules cannot redefine search, projection, exhaustion, validation
-- or commit.  This module also compiles stable option graphs into cached
-- dependency metadata used by recruitment, component isolation and diagnostics.

local Op = require('fibers.op')
local Supply = require('fibers.internal.kernel.supply')
local Algebra = require('fibers.internal.kernel.algebra')

local M = {}

local function encode_result(codec, program, value, session)
  codec = codec or { kind = 'value' }
  local pack = session and function(...)
    return session:pack(...)
  end or Op._pack
  local kind = codec.kind
  if kind == 'constant' then
    return pack(codec.value)
  elseif kind == 'value' then
    return pack(value)
  elseif kind == 'project' then
    return pack(codec.project(value, program))
  end
  error('unknown facility result codec ' .. tostring(kind), 2)
end

M.SUPPLY_NONE = 0
M.SUPPLY_OPAQUE = 1
M.SUPPLY_EXACT = 2

local function programme(kind, fields)
  fields = fields or {}
  fields._fibers_program = true
  fields.kind = kind
  return fields
end

function M.read(location, result)
  return programme('read', { location = location, result = result })
end

function M.patch(location, patch, result)
  return programme('patch', { location = location, patch = patch, result = result })
end

function M.observe(resource, observation, result)
  return programme('observe', { resource = resource, observation = observation, result = result })
end

function M.transition(opts)
  assert(opts and opts.location, 'transition requires location')
  assert(type(opts.rule) == 'table', 'transition requires a rule')
  return programme('transition', opts)
end

function M.version_wait(location, version)
  return programme('version_wait', { location = location, version = version })
end

-- Cached option metadata -------------------------------------------------

-- These caches are advisory. Weak keys alone are insufficient on Lua 5.1 and
-- LuaJIT because they do not provide ephemeron semantics: cached metadata can
-- reach its option/program key through resource locations and retain complete
-- Scope graphs. Weak values make the cache collectable on every supported Lua.
local metadata_cache = setmetatable({}, { __mode = 'kv' })
local active_metadata_cache = setmetatable({}, { __mode = 'kv' })
local preferred_metadata_cache = setmetatable({}, { __mode = 'kv' })

local function empty_metadata()
  return {
    exchanges = {},
    locations = {},
    resources = {},
    node_kinds = {},
    nodes = 0,
    dynamic = false,
    active_dynamic = false,
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
    if key == 'supplies' then
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
  dst.active_dynamic = dst.active_dynamic or src.active_dynamic
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
  if program.patch then
    mark_patch_supply(access, program.location, program.patch)
  end
  if program.bind == 'replace' then
    access.supplies.any = true
  elseif program.bind == 'presence_put' then
    access.supplies.up = true
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
  if kind == 'observe' then
    mark_resource(out, p.resource, { observe = true })
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

local metadata_caches = {
  full = metadata_cache,
  active = active_metadata_cache,
  preferred = preferred_metadata_cache,
}

local describe_mode

describe_mode = function(op, seen, mode)
  if not op then
    return empty_metadata()
  end
  local cache = metadata_caches[mode]
  local cache_key = op.program or op
  local cached = cache[cache_key]
  if cached then
    return cached
  end
  seen = seen or {}
  if seen[op] then
    local recursive = empty_metadata()
    recursive.dynamic = true
    recursive.active_dynamic = true
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
      metadata_merge(out, describe_mode(op.choices[i], seen, mode))
    end
  elseif kind == 'product' then
    for i = 1, #(op.lanes or {}) do
      metadata_merge(out, describe_mode(op.lanes[i], seen, mode))
    end
  elseif kind == 'or_else' then
    metadata_merge(out, describe_mode(op.p, seen, mode))
    if mode ~= 'preferred' then
      metadata_merge(out, describe_mode(op.q, seen, mode))
    end
  elseif kind == 'annotated' or kind == 'map' then
    metadata_merge(out, describe_mode(op.p, seen, mode))
  elseif kind == 'guard' then
    out.dynamic = true
    out.active_dynamic = true
  elseif kind == 'and_then' then
    local prefix = describe_mode(op.p, seen, mode)
    metadata_merge(out, prefix)
    if mode ~= 'active' then
      metadata_merge(out, describe_mode(op.q, seen, mode))
      -- The right-hand operation is dormant for active recruitment. Its full
      -- structure remains visible to preferred-side arbitration, while active
      -- opacity is determined solely by the prefix until sequencing advances.
      out.active_dynamic = describe_mode(op.p, {}, 'active').dynamic == true
    end
  end

  seen[op] = nil
  out.analysable = not out.dynamic
  cache[cache_key] = out
  return out
end

describe = function(op, seen)
  return describe_mode(op, seen, 'full')
end

local function describe_active(op, seen)
  return describe_mode(op, seen, 'active')
end

local function describe_preferred(op, seen)
  return describe_mode(op, seen, 'preferred')
end

function M.preferred_metadata(op)
  return describe_preferred(op, {})
end

function M.has_or_else(op)
  return op and op._contains_or_else == true or false
end

function M.metadata(op)
  local metadata = describe(op)
  if metadata.active == nil then
    metadata.active = describe_active(op, {})
  end
  return metadata
end

function M.active_metadata(value)
  if value and value.kind then
    return describe_active(value, {})
  end
  return value and value.active or value
end

function M.active_dynamic(metadata)
  local active = M.active_metadata(metadata)
  return active and active.dynamic == true
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

function M.supply_relation(metadata, intent)
  metadata = metadata or empty_metadata()
  if M.active_dynamic(metadata) then
    return M.SUPPLY_OPAQUE, 'dynamic'
  end
  if not intent then
    return M.SUPPLY_NONE
  end
  if intent.kind == 'exchange' then
    local roles = metadata.exchanges[intent.resource]
    local opposite = opposite_role(intent.role)
    if roles and opposite and roles[opposite] then
      return M.SUPPLY_EXACT, 'exchange'
    end
    return M.SUPPLY_NONE
  end
  local program = intent.program
  local loc = program and program.location
  local access = loc and metadata.locations[loc]
  local demand = program and program.orientation
  if access and Supply.may_supply(access.supplies, demand) then
    return M.SUPPLY_EXACT, 'location', demand
  end
  return M.SUPPLY_NONE
end

function M.metadata_may_supply(metadata, intent)
  metadata = metadata or empty_metadata()
  if M.active_dynamic(metadata) then
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
  local loc = program and program.location
  local access = loc and metadata.locations[loc]
  local demand = program and program.orientation
  if access and Supply.may_supply(access.supplies, demand) then
    return true, demand and ('location-' .. tostring(demand)) or 'location-any-demand'
  end
  return false, 'none'
end

function M.metadata_may_supply_any(metadata, intents)
  if M.active_dynamic(metadata) then
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
  if M.active_dynamic(metadata) then
    return math.max(1, #(intents or {})), M.SUPPLY_OPAQUE, 'dynamic'
  end
  local score, first_reason = 0, nil
  for i = 1, #(intents or {}) do
    local ok, reason = M.metadata_may_supply(metadata, intents[i])
    if ok then
      score = score + 1
      first_reason = first_reason or reason
    end
  end
  if score == 0 then
    return 0, M.SUPPLY_NONE, 'none'
  end
  return score, M.SUPPLY_EXACT, first_reason
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
  return type(value) == 'table' and value._fibers_cell_wait == true
end

local function is_ready(value)
  return type(value) == 'table' and value._fibers_cell_ready == true
end

local function machine_outcome(program, value, context, occurrence_payload)
  local transition = M.rule(program)
  local payload = occurrence_payload
  if payload == nil then
    payload = program.payload
  end
  if payload == nil then
    payload = {}
  end
  local outcome = transition.step(value, payload, context)
  if is_wait(outcome) then
    return nil
  end
  if not is_ready(outcome) then
    error('machine transition must return Machine.Wait or Machine.Ready', 2)
  end
  if transition.mode == 'query' and outcome.writes then
    error('query transition cannot write', 2)
  end
  return {
    machine = true,
    writes = outcome.writes == true,
    value = outcome.value,
    result = outcome.pack or Op._pack(),
  }
end

function M.result_pack(program, value, session)
  return encode_result(program.result, program, value, session)
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
  if predicate == 'le' then
    return value <= program.threshold
  end
  if predicate == 'eq' then
    return value == program.threshold
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
  return program and program.kind
end

function M.rule(program)
  if M.kind(program) ~= 'transition' or type(program.rule) ~= 'table' then
    error('programme is not a transition rule', 2)
  end
  return program.rule
end

local function witness_cursor(program, rule, value, context, occurrence_payload)
  local source = rule.cursor_factory(value, occurrence_payload or program.payload or {}, context)
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

function M.transition_cursor(program, value, context, phase, occurrence_payload)
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
    local outcome = machine_outcome(program, value, context, occurrence_payload)
    return outcome and one(outcome) or none()
  elseif rule.type == 'witness' then
    return witness_cursor(program, rule, value, context, occurrence_payload)
  end
  error('unknown transition rule type ' .. tostring(rule.type), 2)
end

function M.transition_ready(program, value, context, occurrence_payload)
  local rule = M.rule(program)
  if rule.type == 'machine' and type(rule.ready) == 'function' then
    local result = rule.ready(value, occurrence_payload or program.payload or {}, context or {})
    return result ~= nil and result ~= false and not is_wait(result)
  end
  return M.transition_cursor(program, value, context, 'probe', occurrence_payload):next() ~= nil
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

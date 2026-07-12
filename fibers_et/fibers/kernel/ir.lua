-- Data-only primitive programmes for the transactional substrate.
--
-- Facility APIs compile to these records.  The runtime owns their meaning;
-- facility modules cannot redefine search, projection, exhaustion, validation
-- or commit.

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

-- Attempt an ordinary state transition against the lane-local view.  When its
-- predicate is false, publish the supplied claim programme so a tensor sibling
-- or another participant may satisfy it.
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
    kind = 'put', key = opts.key, value = opts.value, policy = 'overwrite',
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

-- A partial state transition with zero or more witnesses.  `cursor` is a
-- pure factory returning a resumable ordered cursor.  The legacy `enumerate`
-- callback is adapted to a cursor for source compatibility.  Candidates are:
--
--   { value = successor_state, result = packed_result, writes = true|false }
--
-- The evaluator owns ordering, backtracking, exhaustion, validation and commit.
function M.witness_transition(opts)
  assert(opts and opts.location, 'witness transition requires location')
  assert(type(opts.cursor) == 'function' or type(opts.enumerate) == 'function', 'witness transition requires cursor or enumerate')
  opts.order = opts.order or 0
  return programme('witness_transition', opts)
end


function M.version_wait(location, version)
  return programme('version_wait', { location = location, version = version })
end

function M.exchange(resource, role, value)
  return programme('exchange', { resource = resource, role = role, value = value })
end

-- Open a resumable witness cursor.  Resource code may provide a cursor factory;
-- the finite-list adapter is retained for source compatibility.
function M.open_witness_cursor(program, state, payload, context)
  if type(program.cursor) == 'function' then
    local cursor = program.cursor(state, payload or {}, context or {})
    assert(type(cursor) == 'table' and type(cursor.next) == 'function', 'witness cursor factory must return { next = function }')
    return cursor
  end
  local values = program.enumerate(state, payload or {}, context or {}) or {}
  local i = 0
  return { next = function()
    i = i + 1
    return values[i]
  end }
end

function M.witness_ready(program, state, payload, context)
  return M.open_witness_cursor(program, state, payload, context):next() ~= nil
end

local footprint_cache = setmetatable({}, { __mode = 'k' })

local function footprint_merge(dst, src)
  dst.dynamic = dst.dynamic or src.dynamic
  dst.external = dst.external or src.external
  for r, roles in pairs(src.exchanges) do
    local d = dst.exchanges[r] or {}; dst.exchanges[r] = d
    for role in pairs(roles) do d[role] = true end
  end
  for loc in pairs(src.locations) do dst.locations[loc] = true end
  return dst
end

local function footprint_of(op, seen)
  if not op then return { exchanges = {}, locations = {} } end
  local cached = footprint_cache[op]
  if cached then return cached end
  seen = seen or {}
  if seen[op] then return { exchanges = {}, locations = {}, dynamic = true } end
  seen[op] = true
  local out = { exchanges = {}, locations = {} }
  local kind = op.kind
  if kind == 'primitive' then
    local p = op.payload or {}
    if p.kind == 'exchange' then out.exchanges[p.resource] = { [p.role] = true }
    elseif p.location then
      out.locations[p.location] = true
      out.external = p.interest ~= nil or p.absence_check ~= nil
    end
  elseif kind == 'choice' then
    for i = 1, #(op.choices or {}) do footprint_merge(out, footprint_of(op.choices[i], seen)) end
  elseif kind == 'product' then
    for i = 1, #(op.lanes or {}) do footprint_merge(out, footprint_of(op.lanes[i], seen)) end
  elseif kind == 'or_else' then
    footprint_merge(out, footprint_of(op.p, seen)); footprint_merge(out, footprint_of(op.q, seen))
  elseif kind == 'annotated' then
    footprint_merge(out, footprint_of(op.p, seen))
  elseif kind == 'and_then' then
    footprint_merge(out, footprint_of(op.p, seen)); out.dynamic = true
  end
  seen[op] = nil
  footprint_cache[op] = out
  return out
end

function M.footprint(op) return footprint_of(op) end

function M.footprint_may_supply(footprint, intents)
  if footprint.dynamic then return true end
  for i = 1, #(intents or {}) do
    local intent = intents[i]
    if intent.kind == 'exchange' then
      local roles = footprint.exchanges[intent.resource]
      if roles and ((intent.role == 'put' and roles.get) or (intent.role == 'get' and roles.put)) then return true end
    else
      local loc = intent.program and (intent.program.location or intent.program.group)
      if loc and footprint.locations[loc] then return true end
    end
  end
  return false
end

return M

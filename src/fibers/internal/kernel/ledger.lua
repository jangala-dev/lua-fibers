-- Hierarchical speculative delta ledger.
--
-- A segment stores only summaries for locations it writes. Read-only access
-- records one proof-wide committed version and allocates no speculative cell.
-- Materialised values are cached only beside writes, while sibling projection
-- visits a lazily constructed per-location writer frontier.

local Algebra = require('fibers.internal.kernel.algebra')
local Path = require('fibers.internal.kernel.path')

local M = { ABSENT = Algebra.ABSENT }

local next_location_id = 0

function M.new_location(opts)
  opts = opts or {}
  next_location_id = next_location_id + 1
  local algebra = Algebra.get(assert(opts.algebra, 'location algebra is required'))
  local location = {
    id = next_location_id,
    name = opts.name or ('location-' .. tostring(next_location_id)),
    algebra = algebra,
    domain = opts.domain or 'plain',
    value = opts.value,
    version = opts.version or 0,
    owner = opts.owner,
    key = opts.key,
    apply = opts.apply,
    clone_value = opts.clone_value,
    put_equal = opts.put_equal == true,
    remove_idempotent = opts.remove_idempotent ~= false,
  }
  location.tags = { stock = {}, present = {}, absent = {} }
  return location
end

local function set(trail, target, key, value)
  if trail then
    trail:set(target, key, value)
  else
    target[key] = value
  end
end

local function push(trail, target, value)
  if trail then
    trail:push(target, value)
  else
    target[#target + 1] = value
  end
end

function M.begin_state(state)
  state.ledger = {
    state = state,
    observed = {},
    writers = {},
  }
end

function M.discard_state(state)
  state.ledger = nil
end

function M.invalidate(state)
  if state and state.ledger then
    state.ledger.writers = {}
  end
end

function M.new_segment(root_id, scope_path, source, id, segment, state)
  segment = segment or {}
  segment.id = id
  segment.parent = source
  segment.values = segment.values or {} -- materialised values for locally written locations
  segment.delta = segment.delta or {}
  segment.root_id = root_id
  segment.scope_path = scope_path
  segment.retired = false
  local ledger = source and source.ledger or state and state.ledger or { observed = {}, writers = {} }
  ledger.observed = ledger.observed or {}
  ledger.writers = ledger.writers or {}
  segment.ledger = ledger
  return segment
end

local function observe(segment, location, trail)
  local observed = segment.ledger.observed
  local version = observed[location]
  if version == nil then
    set(trail, observed, location, location.version or 0)
  elseif version ~= (location.version or 0) then
    return false, 'observation-conflict'
  end
  return true
end

function M.observe(segment, location, trail)
  return observe(segment, location, trail)
end

local function inherited_value(segment, location, trail)
  local cached = segment.values[location]
  if cached ~= nil then
    return cached
  end
  if segment.parent then
    return M.read(segment.parent, location, trail)
  end
  return location.value
end

function M.read(segment, location, trail)
  observe(segment, location, trail)
  local value = inherited_value(segment, location, trail)
  local summary = segment.delta[location]
  if summary and segment.values[location] == nil then
    value = Algebra.apply(location, value, summary)
  end
  return value
end

local function stage_summary(segment, location, patch, trail)
  local old = segment.delta[location]
  local summary = Algebra.stage(location, old, patch, trail)
  if summary ~= old then
    set(trail, segment.delta, location, summary)
  end
end

function M.stage(segment, location, patch, trail)
  observe(segment, location, trail)
  local value = M.read(segment, location, trail)
  stage_summary(segment, location, patch, trail)
  set(trail, segment.values, location, Algebra.apply(location, value, patch))
  segment.ledger.writers[location] = nil
  return true
end

local function ensure_state_ledger(state)
  if not state.ledger then
    M.begin_state(state)
  end
  for _, segment in pairs(state.segments or {}) do
    segment.ledger = segment.ledger or state.ledger
  end
  return state.ledger
end

local function writer_bucket(state, location)
  local ledger = ensure_state_ledger(state)
  local bucket = ledger.writers[location]
  if bucket then
    return bucket
  end
  bucket = { list = {} }
  local ids = {}
  for id in pairs(state.segments) do
    ids[#ids + 1] = id
  end
  table.sort(ids)
  for i = 1, #ids do
    local segment = state.segments[ids[i]]
    if not segment.retired and rawget(segment.delta, location) then
      bucket.list[#bucket.list + 1] = segment
    end
  end
  ledger.writers[location] = bucket
  return bucket
end

local function visible_patch(location, patch, relation, orientation)
  if relation == 'external' or relation == 'interacting' then
    return patch
  elseif relation == 'independent' then
    return Algebra.constraint(location, patch, orientation)
  end
end

function M.project(state, task, location, orientation, trail)
  ensure_state_ledger(state)
  local own = state.segments[task.segment_id]
  local value = M.read(own, location, trail)
  local combined
  local bucket = writer_bucket(state, location)
  for i = 1, #bucket.list do
    local segment = bucket.list[i]
    local patch = segment.delta[location]
    if segment ~= own and not segment.retired and patch then
      local relation = Path.relation(task.root_id, task.scope_path, segment.root_id, segment.scope_path)
      local visible = visible_patch(location, patch, relation, orientation)
      if visible then
        local mode = relation == 'interacting' and 'interacting'
          or relation == 'external' and 'external'
          or 'independent'
        combined = Algebra.join(location, combined, visible, mode)
        if not combined then
          return nil, nil, 'projection-conflict'
        end
      end
    end
  end
  if combined then
    value = Algebra.apply(location, value, combined)
  end
  return value
end

function M.project_machine(state, task, location, succeeds, accepts_supply, trail)
  ensure_state_ledger(state)
  local own = state.segments[task.segment_id]
  local value = M.read(own, location, trail)
  local steps = {}
  local bucket = writer_bucket(state, location)
  for i = 1, #bucket.list do
    local segment = bucket.list[i]
    local patch = segment.delta[location]
    if segment ~= own and not segment.retired and patch then
      local relation = Path.relation(task.root_id, task.scope_path, segment.root_id, segment.scope_path)
      if relation == 'external' or relation == 'interacting' or relation == 'independent' then
        Algebra.serialise(location, patch, relation, steps)
      end
    end
  end
  table.sort(steps, function(left, right)
    return left.serial < right.serial
  end)
  for i = 1, #steps do
    local step = steps[i]
    local restricted = step.relation == 'independent' or not accepts_supply
    if restricted then
      local before = succeeds and succeeds(value) or false
      local after = succeeds and succeeds(step.value) or false
      if before or not after then
        value = step.value
      end
    else
      value = step.value
    end
  end
  return value
end

function M.join_segments(parent, children, mode, trail)
  local writes = {}
  for i = 1, #children do
    for location, patch in pairs(children[i].delta) do
      local merged, err = Algebra.join(location, writes[location], patch, mode or 'independent')
      if not merged then
        return false, err
      end
      writes[location] = merged
    end
  end
  for location, patch in pairs(writes) do
    M.stage(parent, location, patch, trail)
  end
  for i = 1, #children do
    set(trail, children[i], 'retired', true)
  end
  return true
end

function M.collect_candidate(root_segments)
  local observations = root_segments[1] and root_segments[1].ledger.observed or nil
  local writes
  for i = 1, #root_segments do
    for location, patch in pairs(root_segments[i].delta) do
      writes = writes or {}
      local merged, err = Algebra.join(location, writes[location], patch, 'external')
      if not merged then
        return nil, nil, err
      end
      writes[location] = merged
    end
  end
  return observations, writes
end

function M.validate(observations)
  for location, version in pairs(observations or {}) do
    if (location.version or 0) ~= version then
      return false, 'stale-location'
    end
  end
  return true
end

function M.commit(writes)
  for location, summary in pairs(writes or {}) do
    local value = Algebra.apply(location, location.value, summary)
    location.value = value
    location.version = (location.version or 0) + 1
    if location.apply then
      location.apply(value, location)
    end
  end
end

return M

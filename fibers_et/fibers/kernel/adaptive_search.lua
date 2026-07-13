-- Adaptive search policy, exact state identity and retained per-plan proofs.
--
-- Policy and mechanism live together so economic activation cannot drift from
-- the memoisation and no-good structures it controls.

local Policy = {}
Policy.__index = Policy

local function integer(value, default, minimum)
  value = math.floor(tonumber(value) or default)
  if value < (minimum or 0) then
    value = minimum or 0
  end
  return value
end

function Policy.new(opts)
  opts = opts or {}
  return setmetatable({
    state_memoization = opts.state_memoization ~= false,
    refutation_cache = opts.refutation_cache ~= false,
    plan_reuse = opts.plan_reuse ~= false,
    resumable_search = opts.resumable_search ~= false,
    state_min_steps = integer(opts.state_memoization_min_steps, 48),
    state_min_intents = integer(opts.state_memoization_min_intents, 0),
    supplier_min_steps = integer(opts.refutation_cache_min_steps, 48),
    plan_reuse_threshold = integer(opts.plan_reuse_threshold, 16, 1),
    retry_min_steps = integer(opts.retry_retention_min_steps, 8),
    retry_min_component = integer(opts.retry_retention_min_component, 8, 1),
  }, Policy)
end

function Policy:state_eligible(component)
  return self.state_memoization and not (component and component.cacheable == false)
end

function Policy:supplier_eligible(component)
  return self.refutation_cache and not (component and component.cacheable == false)
end

function Policy:state_active(state)
  if not self:state_eligible(state.component) then
    return false
  end
  local work = state.search_work and state.search_work.steps or state.search_steps or 0
  return work >= self.state_min_steps and #(state.intents or {}) >= self.state_min_intents
end

function Policy:supplier_active(state)
  if not self:supplier_eligible(state.component) then
    return false
  end
  local work = state.search_work and state.search_work.steps or state.search_steps or 0
  return work >= self.supplier_min_steps
end

function Policy:retry_candidate(session, component)
  if not self.resumable_search or not self.plan_reuse then
    return false, 'disabled'
  end
  if not session or session.disposed or not session.finished or session.result_kind ~= 'retry' then
    return false, 'not-retry'
  end
  local state = session.state
  local component_size = component and component.size or 1
  if
    component_size >= self.retry_min_component
    or (state.search_steps or 0) >= self.retry_min_steps
  then
    return true
  end
  local intents = state.intents or {}
  if #intents == 1 and intents[1].kind == 'exchange' then
    return true
  end
  if session.result_refutation and #(session.result_refutation.interests or {}) > 0 then
    return true
  end
  return false, 'cheap'
end

function Policy:plan_cache_candidate(pending_count)
  return self.plan_reuse and pending_count >= self.plan_reuse_threshold
end

local IR = require('fibers.kernel.ir')

local M = {}

-- Cheap, order-sensitive fingerprint used only as an activation filter.  It is
-- never accepted as proof of equality: an exact identity-aware signature is
-- still required before a memoised refutation may be reused.  The first
-- occurrence of a fingerprint pays no exact-key cost; the second occurrence
-- enables exact memoisation for that apparent repeated world.
local object_ids = setmetatable({}, { __mode = 'k' })
local next_object_id = 0
local HASH_MOD = 2147483629

local function object_id(value)
  local kind = type(value)
  if kind == 'nil' then
    return 0
  end
  if kind == 'boolean' then
    return value and 1 or 2
  end
  if kind == 'number' then
    local n = value
    if n ~= n then
      return 3
    end
    n = math.floor(math.abs(n) * 1009 + 0.5)
    return n % HASH_MOD
  end
  if kind == 'string' then
    local h = #value + 17
    for i = 1, #value do
      h = (h * 131 + value:byte(i)) % HASH_MOD
    end
    return h
  end
  local id = object_ids[value]
  if not id then
    next_object_id = next_object_id + 1
    id = next_object_id
    object_ids[value] = id
  end
  return id
end

local function mix(h, value)
  return (h * 65599 + object_id(value) + 97) % HASH_MOD
end

local function quick_fingerprint(state)
  local h1, h2 = 17, 29
  h1 = mix(h1, state.focus)
  h2 = mix(h2, state.next_machine_serial or 0)
  h1 = mix(h1, state.active_head or 1)
  h2 = mix(h2, #(state.active or {}))
  h1 = mix(h1, #(state.intents or {}))
  h2 = mix(h2, state.used_fallback == true)

  -- Roots and views are maps, so combine their rows commutatively.  Intent and
  -- active order remain ordered because that order can affect later traversal.
  local root_sum, root_sq = 0, 0
  for id, root in pairs(state.roots or {}) do
    local row = mix(mix(mix(11, id), root.request), root.view_id)
    row = mix(row, root.done == true)
    row = mix(row, root.outcome and root.outcome.pack)
    root_sum = (root_sum + row) % HASH_MOD
    root_sq = (root_sq + row * row) % HASH_MOD
  end
  h1 = mix(h1, root_sum)
  h2 = mix(h2, root_sq)

  for i = 1, #(state.active or {}) do
    h1 = mix(h1, state.active[i])
    h2 = mix(h2, i < (state.active_head or 1))
  end

  for i = 1, #(state.intents or {}) do
    local intent = state.intents[i]
    local program = intent.program
    local location = program and (program.location or program.group)
    h1 = mix(h1, intent.root_id)
    h1 = mix(h1, intent.kind)
    h1 = mix(h1, intent.resource)
    h1 = mix(h1, location)
    h2 = mix(h2, intent.role)
    h2 = mix(h2, intent.value)
    h2 = mix(h2, intent.task_id)
    h2 = mix(h2, intent.symmetry_key)
  end

  local delta_sum, delta_sq = 0, 0
  for _, view in pairs(state.views or {}) do
    for location, patch in pairs(view.delta or {}) do
      local row = mix(mix(mix(23, view.root_id), location), patch and patch.kind)
      if patch then
        row = mix(row, patch.value)
        row = mix(row, patch.delta)
        row = mix(row, #(patch.steps or patch.ops or {}))
      end
      delta_sum = (delta_sum + row) % HASH_MOD
      delta_sq = (delta_sq + row * row) % HASH_MOD
    end
  end
  h1 = mix(h1, delta_sum)
  h2 = mix(h2, delta_sq)
  return h1, h2
end

local function sorted_keys(map)
  local out = {}
  for key in pairs(map or {}) do
    out[#out + 1] = key
  end
  table.sort(out, function(a, b)
    if type(a) == type(b) and (type(a) == 'number' or type(a) == 'string') then
      return a < b
    end
    return tostring(a) < tostring(b)
  end)
  return out
end

local function value_key(value)
  local kind = type(value)
  if kind == 'nil' then
    return 'nil'
  end
  if kind == 'boolean' then
    return value and 'b:1' or 'b:0'
  end
  if kind == 'number' then
    return 'n:' .. string.format('%.17g', value)
  end
  if kind == 'string' then
    return 's:' .. #value .. ':' .. value
  end
  return kind .. ':' .. tostring(value)
end

local function pack_key(pack)
  if not pack then
    return '-'
  end
  local parts = { tostring(pack.n or #pack) }
  for i = 1, pack.n or #pack do
    parts[#parts + 1] = value_key(pack[i])
  end
  return table.concat(parts, ',')
end

local function scope_key(path)
  local parts = {}
  if path and path._fibers_scope_path then
    local node = path
    while node do
      parts[#parts + 1] = table.concat({
        tostring(node.group_id or ''),
        tostring(node.mode or ''),
        tostring(node.lane or ''),
      }, ':')
      node = node.parent
    end
    local i, j = 1, #parts
    while i < j do
      parts[i], parts[j] = parts[j], parts[i]
      i, j = i + 1, j - 1
    end
  else
    for i = 1, #(path or {}) do
      local entry = path[i]
      parts[#parts + 1] = table.concat({
        tostring(entry.group_id or ''),
        tostring(entry.mode or ''),
        tostring(entry.lane or ''),
      }, ':')
    end
  end
  return table.concat(parts, '/')
end

local function frame_key(frame)
  return table.concat({
    tostring(frame.kind or ''),
    tostring(frame.phase or ''),
    tostring(frame.group_id or ''),
    tostring(frame.lane or ''),
    tostring(frame.fn or ''),
    tostring(frame.cache_key or ''),
    tostring(frame.continuation_footprint or ''),
    value_key(frame.previous_symmetry),
  }, ':')
end

local function patch_key(patch)
  if not patch then
    return '-'
  end
  local parts = { tostring(patch.kind or '') }
  if patch.kind == 'replace' then
    parts[#parts + 1] = value_key(patch.value)
  elseif patch.kind == 'add' then
    parts[#parts + 1] = value_key(patch.delta)
  elseif patch.kind == 'machine' then
    for i = 1, #(patch.steps or {}) do
      local step = patch.steps[i]
      parts[#parts + 1] = tostring(step.serial or '') .. '=' .. value_key(step.value)
    end
  else
    for i = 1, #(patch.ops or {}) do
      local op = patch.ops[i]
      parts[#parts + 1] = table.concat({
        tostring(op.op or ''),
        value_key(op.key),
        value_key(op.value),
        tostring(op.policy or ''),
      }, ':')
    end
  end
  return table.concat(parts, ',')
end

local function outcome_key(outcome)
  if not outcome then
    return '-'
  end
  return pack_key(outcome.pack) .. '/w:' .. tostring(outcome.wrap or '')
end

local function task_key(task, task_id)
  local row = {
    'task',
    tostring(task.id or task_id or ''),
    tostring(task.root_id or ''),
    tostring(task.view_id or ''),
    tostring(task.status or ''),
    tostring(task.expr and task.expr._id or ''),
    tostring(task.choice_serial or 0),
    value_key(task.symmetry_key),
    scope_key(task.scope_path),
  }
  for i = 1, #(task.frames or {}) do
    row[#row + 1] = frame_key(task.frames[i])
  end
  return table.concat(row, ':')
end

local function intent_requirement_key(intent)
  if intent.kind == 'exchange' then
    return table.concat({ 'exchange', tostring(intent.resource), tostring(intent.role or '') }, ':')
  end
  local location = intent.program and (intent.program.location or intent.program.group)
  return table.concat({ 'location', tostring(location and (location.id or location) or '') }, ':')
end

-- A narrow semantic no-good: with this exact set of entered/excluded requests,
-- no remaining request footprint can supply any of these unresolved
-- requirements.  Values and continuation state are deliberately absent because
-- IR.metadata_may_supply uses only resource/role or location supply metadata.
function M.supplier_signature(state, intents)
  local requirements = {}
  for i = 1, #(intents or {}) do
    requirements[i] = intent_requirement_key(intents[i])
  end
  table.sort(requirements)
  local entered = sorted_keys(state.roots)
  local excluded = sorted_keys(state.excluded_roots)
  local parts = { 'supplier', table.concat(requirements, ',') }
  for i = 1, #entered do
    parts[#parts + 1] = 'in:' .. tostring(entered[i])
  end
  for i = 1, #excluded do
    parts[#parts + 1] = 'out:' .. tostring(excluded[i])
  end
  return table.concat(parts, '|')
end

-- Authoritative exact identity for both memoisation and diagnostic state observation.
function M.signature(state, terminal)
  local parts = {
    terminal and 'terminal' or 'branch',
    'focus=' .. tostring(state.focus),
    'fallback=' .. tostring(state.used_fallback == true),
    'serial=' .. tostring(state.next_machine_serial or 0),
    'active_head=' .. tostring(state.active_head or 1),
  }

  local root_ids = sorted_keys(state.roots)
  for i = 1, #root_ids do
    local id, root = root_ids[i], state.roots[root_ids[i]]
    parts[#parts + 1] = table.concat({
      'root',
      tostring(id),
      tostring(root.request or ''),
      root.done and '1' or '0',
      tostring(root.view_id or ''),
      outcome_key(root.outcome),
    }, ':')
  end

  local excluded = sorted_keys(state.excluded_roots)
  for i = 1, #excluded do
    parts[#parts + 1] = 'excluded:' .. tostring(excluded[i])
  end

  local task_ids = sorted_keys(state.tasks)
  for i = 1, #task_ids do
    parts[#parts + 1] = task_key(state.tasks[task_ids[i]], task_ids[i])
  end

  for i = 1, #(state.active or {}) do
    parts[#parts + 1] = table.concat({
      'active',
      tostring(i),
      i < (state.active_head or 1) and 'consumed' or 'pending',
      tostring(state.active[i] or ''),
    }, ':')
  end

  local group_ids = sorted_keys(state.groups)
  for i = 1, #group_ids do
    local group = state.groups[group_ids[i]]
    local row = {
      'group',
      tostring(group.id or group_ids[i]),
      tostring(group.parent_task or ''),
      tostring(group.parent_view or ''),
      tostring(group.mode or ''),
      tostring(group.count or 0),
      tostring(group.completed or 0),
    }
    for lane = 1, group.count or 0 do
      row[#row + 1] = table.concat({
        'lane',
        tostring(lane),
        tostring((group.lane_views or {})[lane] or ''),
        outcome_key((group.lane_outcomes or {})[lane]),
      }, '=')
    end
    parts[#parts + 1] = table.concat(row, ':')
  end

  local intents = {}
  for i = 1, #(state.intents or {}) do
    local intent = state.intents[i]
    local location = intent.program and (intent.program.location or intent.program.group)
    local task = state.tasks and state.tasks[intent.task_id]
    local row = {
      'intent',
      tostring(intent.task_id or ''),
      tostring(intent.root_id or ''),
      tostring(intent.kind or ''),
      tostring(intent.program or ''),
      tostring(intent.resource or ''),
      tostring(location and location.id or ''),
      tostring(intent.role or ''),
      value_key(intent.value),
      value_key(intent.symmetry_key),
      scope_key(intent.scope_path),
      tostring(intent.interest and (intent.interest.id or intent.interest) or ''),
      tostring(intent.absence_check or ''),
      tostring(task and task.view_id or ''),
    }
    for j = 1, #((task and task.frames) or {}) do
      row[#row + 1] = frame_key(task.frames[j])
    end
    intents[#intents + 1] = table.concat(row, ':')
  end
  table.sort(intents)
  for i = 1, #intents do
    parts[#parts + 1] = intents[i]
  end

  local view_ids = sorted_keys(state.views)
  for i = 1, #view_ids do
    local view = state.views[view_ids[i]]
    local row = {
      'view',
      tostring(view_ids[i]),
      tostring(view.root_id or ''),
      tostring(view.parent and view.parent.id or ''),
      tostring(view.merged == true),
      scope_key(view.scope_path),
    }
    local locations = {}
    for location in pairs(view.cells or {}) do
      locations[location] = true
    end
    for location in pairs(view.delta or {}) do
      locations[location] = true
    end
    local ordered = sorted_keys(locations)
    for j = 1, #ordered do
      local location = ordered[j]
      local cell = (view.cells or {})[location]
      row[#row + 1] = table.concat({
        tostring(location.id or location),
        tostring(cell and cell.version or location.version or 0),
        value_key(cell and cell.value),
        patch_key((view.delta or {})[location]),
      }, '=')
    end
    parts[#parts + 1] = table.concat(row, ':')
  end

  for i = 1, #(state.effects or {}) do
    parts[#parts + 1] = 'effect:' .. tostring(state.effects[i])
  end
  for i = 1, #(state.negative_checks or {}) do
    local check = state.negative_checks[i]
    parts[#parts + 1] = 'negative:' .. tostring(check and (check.id or check) or '')
  end
  for i = 1, #(state.fallback_interests or {}) do
    local interest = state.fallback_interests[i]
    parts[#parts + 1] = 'interest:' .. tostring(interest and (interest.id or interest) or '')
  end

  return table.concat(parts, '|')
end

local function copy_array(values)
  local out = {}
  for i = 1, #(values or {}) do
    out[i] = values[i]
  end
  return out
end

function M.copy_refutation(refutation)
  if not refutation then
    return nil
  end
  return {
    interests = copy_array(refutation.interests),
    checks = copy_array(refutation.checks),
  }
end

local function ensure_cacheable(cache)
  if cache.cacheable ~= nil then
    return cache.cacheable
  end
  local cacheable = cache.component == nil or cache.component.cacheable ~= false
  if cacheable and cache.requests then
    for _, request in pairs(cache.requests) do
      local metadata = request.metadata or request.footprint or IR.metadata(request.op)
      request.metadata, request.footprint = metadata, metadata
      if metadata.dynamic or metadata.external then
        cacheable = false
        break
      end
    end
  end
  cache.cacheable = cacheable
  return cacheable
end

local function initialise(cache, state)
  local runtime = state.runtime
  cache.plan_id = state.plan_id
  cache.runtime = runtime
  cache.component = state.component
  cache.profile_plan = state.profile_plan
  cache.requests = state.requests
  cache.cacheable = nil
  cache.states = nil
  cache.supplier_refutations = nil
  local policy = runtime.search_policy
  cache.state_min_steps = policy and policy.state_min_steps
    or runtime.state_memoization_min_steps
    or 0
  cache.state_min_intents = policy and policy.state_min_intents
    or runtime.state_memoization_min_intents
    or 0
  cache.refutation_min_steps = policy and policy.supplier_min_steps
    or runtime.refutation_cache_min_steps
    or 0
  cache.fingerprint_seen = nil
  return cache
end

function M.ensure(state)
  local runtime = state.runtime
  -- Production search sessions own their cache so a suspended proof retains
  -- memoised refutations.  The reference evaluator continues to share the
  -- historical runtime scratch cache across copy-on-branch states.
  local cache = state.search_cache
  if cache then
    if cache.plan_id ~= state.plan_id then
      initialise(cache, state)
    end
    return cache
  end
  if state.session then
    cache = {}
    state.search_cache = cache
  else
    cache = runtime._search_cache_scratch
    if not cache then
      cache = {}
      runtime._search_cache_scratch = cache
    end
  end
  if cache.plan_id ~= state.plan_id then
    initialise(cache, state)
  end
  return cache
end

function M.finish(state)
  local cache = state.search_cache or state.runtime._search_cache_scratch
  if not cache or cache.plan_id ~= state.plan_id then
    return
  end
  cache.plan_id = nil
  cache.runtime = nil
  cache.component = nil
  cache.profile_plan = nil
  cache.requests = nil
  cache.cacheable = nil
  cache.states = nil
  cache.supplier_refutations = nil
  cache.fingerprint_seen = nil
end

function M.work_steps(state)
  return state.search_work and state.search_work.steps or state.search_steps or 0
end

function M.probe_state(cache, state)
  if not M.state_enabled(cache, state) then
    return nil
  end
  local h1, h2 = quick_fingerprint(state)
  local seen = cache.fingerprint_seen
  if not seen then
    seen = {}
    cache.fingerprint_seen = seen
  end
  local row = seen[h1]
  if not row then
    row = {}
    seen[h1] = row
  end
  local count = (row[h2] or 0) + 1
  row[h2] = count
  local plan = cache.profile_plan
  if plan then
    plan.state_fingerprint_probes = (plan.state_fingerprint_probes or 0) + 1
    if count > 1 then
      plan.state_fingerprint_repeats = (plan.state_fingerprint_repeats or 0) + 1
    end
  end
  -- The second occurrence is the first point at which exact-key construction
  -- can plausibly repay its cost.  A refutation stored here is available to the
  -- third and later equivalent occurrence.  Unique states never build a key.
  if count < 2 then
    return nil
  end
  return M.signature(state, false)
end

function M.state_enabled(cache, state)
  if not cache or not ensure_cacheable(cache) then
    return false
  end
  local policy = cache.runtime.search_policy
  if policy then
    if not policy:state_active(state) then
      return false
    end
  elseif
    cache.runtime.state_memoization == false
    or M.work_steps(state) < (cache.state_min_steps or 0)
    or #(state.intents or {}) < (cache.state_min_intents or 0)
  then
    return false
  end
  if not cache.states then
    cache.states = {}
  end
  return cache.states
end

function M.supplier_enabled(cache, state)
  if not cache or not ensure_cacheable(cache) then
    return false
  end
  local policy = cache.runtime.search_policy
  if policy then
    if not policy:supplier_active(state) then
      return false
    end
  elseif
    cache.runtime.refutation_cache == false
    or M.work_steps(state) < (cache.refutation_min_steps or 0)
  then
    return false
  end
  if not cache.supplier_refutations then
    cache.supplier_refutations = {}
  end
  return cache.supplier_refutations
end

local function hit(cache, name)
  local plan = cache.profile_plan
  if plan then
    plan[name] = (plan[name] or 0) + 1
  end
end

function M.get_state(cache, signature)
  local value = cache and cache.states and cache.states[signature]
  if value then
    hit(cache, 'state_memo_hits')
    return M.copy_refutation(value)
  end
end

function M.put_state(cache, signature, refutation)
  if not (cache and cache.states and signature and refutation) then
    return
  end
  if cache.states[signature] == nil then
    cache.states[signature] = M.copy_refutation(refutation)
    hit(cache, 'state_memo_stores')
  end
end

function M.get_no_supplier(cache, signature)
  if not (cache and cache.supplier_refutations and signature) then
    return false
  end
  if cache.supplier_refutations[signature] then
    hit(cache, 'refutation_cache_hits')
    hit(cache, 'supplier_refutation_hits')
    return true
  end
  return false
end

function M.put_no_supplier(cache, signature)
  if not (cache and cache.supplier_refutations and signature) then
    return
  end
  if cache.supplier_refutations[signature] == nil then
    cache.supplier_refutations[signature] = true
    hit(cache, 'refutation_cache_stores')
    hit(cache, 'supplier_refutation_stores')
  end
end

M.Policy = Policy
return M

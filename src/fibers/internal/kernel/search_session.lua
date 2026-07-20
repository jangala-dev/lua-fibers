-- Ownership shell for one production-machine proof attempt.
--
-- The session owns one production-machine proof attempt, including its
-- explicit alternative stack.  Search control no longer depends on the Lua
-- call stack; a later driver may therefore retain and resume this object.

local SearchCache = require('fibers.internal.kernel.adaptive_search')
local Op = require('fibers.op')
local Frontier = require('fibers.internal.kernel.frontier')

local Session = {}
Session.__index = Session

local STATE_ARENAS = {
  'tasks',
  'active',
  'roots',
  'groups',
  'views',
  'intents',
  'intent_by_id',
  'effects',
  'negative_checks',
  'fallback_interests',
  'excluded_roots',
  'search_cache',
}
local SESSION_ARENAS = {
  '_arena_root_views',
  '_arena_participants',
  '_arena_commit_requests',
  '_arena_commit_outcomes',
}

local function map_count(values)
  local n = 0
  for _ in pairs(values or {}) do
    n = n + 1
  end
  return n
end


local function profile_component_shape(requests, component)
  local ids = component and component.ids
  local option_nodes = 0
  local dynamic_roots = 0
  local external_roots = 0
  local node_kinds = {}
  local locations = {}
  local resources = {}
  local exchanges = {}
  local request_summaries = {}

  local function add_request(request)
    local metadata = request and (request.metadata or request.footprint)
    if not metadata then
      return
    end
    request_summaries[#request_summaries + 1] = {
      id = request.id,
      name = request.name,
      dynamic = metadata.dynamic == true,
      external = metadata.external == true,
      nodes = metadata.nodes or 0,
      kinds = metadata.node_kinds,
    }
    option_nodes = option_nodes + (metadata.nodes or 0)
    if metadata.dynamic then
      dynamic_roots = dynamic_roots + 1
    end
    if metadata.external then
      external_roots = external_roots + 1
    end
    for kind, count in pairs(metadata.node_kinds or {}) do
      node_kinds[kind] = (node_kinds[kind] or 0) + count
    end
    for location in pairs(metadata.locations or {}) do
      locations[location] = true
    end
    for resource in pairs(metadata.resources or {}) do
      resources[resource] = true
    end
    for resource in pairs(metadata.exchanges or {}) do
      exchanges[resource] = true
    end
  end

  if ids then
    for i = 1, #ids do
      add_request(requests[ids[i]])
    end
  else
    for _, request in pairs(requests) do
      add_request(request)
    end
  end

  return {
    option_nodes = option_nodes,
    option_dynamic_roots = dynamic_roots,
    option_external_roots = external_roots,
    dependency_locations = map_count(locations),
    dependency_resources = map_count(resources),
    dependency_exchanges = map_count(exchanges),
    option_node_kinds = node_kinds,
    request_summaries = request_summaries,
  }
end

local native_table_clear = table.clear
local function clear_table(values)
  if not values then
    return values
  end
  if native_table_clear then
    native_table_clear(values)
  else
    for key in pairs(values) do
      values[key] = nil
    end
  end
  return values
end


local function record_pool_name(kind)
  return '_record_pool_' .. kind
end

function Session:acquire_record(kind)
  if not self.runtime.record_pool then
    if kind == 'task' then
      return { frames = {} }
    end
    if kind == 'view' then
      return { cells = {}, delta = {} }
    end
    if kind == 'group' then
      return { lane_views = {}, lane_outcomes = {} }
    end
    return {}
  end
  local name = record_pool_name(kind)
  local pool = self[name]
  if not pool then
    pool = {}
    self[name] = pool
  end
  local n, record = #pool, nil
  if n > 0 then
    record = pool[n]
    pool[n] = nil
  else
    record = {}
  end
  -- Pooled records are cleared before release.  Acquisition only restores
  -- their structural child arrays, avoiding a second full table clear on the
  -- common reuse path.
  if kind == 'task' then
    record.frames = record.frames or {}
  elseif kind == 'view' then
    record.cells = record.cells or {}
    record.delta = record.delta or {}
  elseif kind == 'group' then
    record.lane_views = record.lane_views or {}
    record.lane_outcomes = record.lane_outcomes or {}
  end
  return record
end

local function recycle_record(session, kind, record)
  if not record or not session.runtime.record_pool then
    return
  end
  local name = record_pool_name(kind)
  local pool = session[name]
  if not pool then
    pool = {}
    session[name] = pool
  end
  if kind == 'task' then
    local frames = record.frames or {}
    clear_table(frames)
    clear_table(record)
    record.frames = frames
  elseif kind == 'view' then
    local cells, delta = record.cells or {}, record.delta or {}
    clear_table(cells)
    clear_table(delta)
    clear_table(record)
    record.cells, record.delta = cells, delta
  elseif kind == 'group' then
    local lane_views, lane_outcomes = record.lane_views or {}, record.lane_outcomes or {}
    clear_table(lane_views)
    clear_table(lane_outcomes)
    clear_table(record)
    record.lane_views, record.lane_outcomes = lane_views, lane_outcomes
  else
    clear_table(record)
  end
  pool[#pool + 1] = record
end

function Session:_recycle_state_records()
  local state = self.state
  if not state then
    return
  end
  local seen = self._outcome_recycle_seen or {}
  self._outcome_recycle_seen = seen
  clear_table(seen)
  local function recycle_outcome(outcome, owner)
    if outcome and outcome ~= owner and not seen[outcome] then
      seen[outcome] = true
      recycle_record(self, 'outcome', outcome)
    end
  end
  for _, root in pairs(state.roots or {}) do
    recycle_outcome(root.outcome, root)
  end
  for _, group in pairs(state.groups or {}) do
    for i = 1, #(group.lane_outcomes or {}) do
      recycle_outcome(group.lane_outcomes[i])
    end
  end
  for _, record in pairs(state.tasks or {}) do
    recycle_record(self, 'task', record)
  end
  for _, record in pairs(state.views or {}) do
    recycle_record(self, 'view', record)
  end
  for i = 1, #(state.intents or {}) do
    recycle_record(self, 'intent', state.intents[i])
  end
  for _, record in pairs(state.groups or {}) do
    recycle_record(self, 'group', record)
  end
end

local function arena(state, name)
  local values = state[name]
  if not values then
    values = {}
    state[name] = values
  end
  -- SearchSession:discard clears every arena before returning a session to the
  -- pool.  Clearing again here doubles the cost of a trivial transaction.
  return values
end

function Session.new(runtime, requests, focus_id, component, search_limit)
  runtime = assert(runtime, 'SearchSession requires a runtime')
  requests = assert(requests, 'SearchSession requires requests')
  focus_id = assert(focus_id, 'SearchSession requires a focus')
  if not requests[focus_id] then
    return nil
  end

  runtime.stats.plans = runtime.stats.plans + 1
  runtime.stats.search_sessions = (runtime.stats.search_sessions or 0) + 1
  local instrumentation = runtime.instrumentation
  if instrumentation then
    instrumentation:inc('search_sessions')
  end

  local pending = instrumentation and map_count(requests) or 0
  local shape = instrumentation and profile_component_shape(requests, component) or nil
  local profile_plan = instrumentation
      and instrumentation:begin_plan({
        focus = focus_id,
        pending = pending,
        machine = 'trail',
        total_pending = component and component.total or pending,
        component_size = component and component.size or pending,
        component_dynamic = component and component.dynamic or 0,
        component_global = component and component.global == true or false,
        component_edge_visits = component and component.edge_visits or 0,
        option_nodes = shape.option_nodes,
        option_dynamic_roots = shape.option_dynamic_roots,
        option_external_roots = shape.option_external_roots,
        dependency_locations = shape.dependency_locations,
        dependency_resources = shape.dependency_resources,
        dependency_exchanges = shape.dependency_exchanges,
        option_node_kinds = shape.option_node_kinds,
        request_summaries = shape.request_summaries,
      })
    or nil

  local focus_request = requests[focus_id]
  local focus_metadata = component and focus_request and (focus_request.metadata or focus_request.footprint)
  if component and focus_metadata and (focus_metadata.node_kinds or {}).choice then
    runtime:_ensure_component_coordinator(component)
  end
  local policy = runtime.search_policy
  -- Semantic eligibility is checked only if the observed work crosses the
  -- activation threshold.  The common path therefore records the inexpensive
  -- runtime switches without invoking adaptive-policy methods per plan.
  local state_memoization_possible = runtime.state_memoization ~= false
  local refutation_cache_possible = runtime.refutation_cache ~= false

  local session = runtime:_acquire_search_session()
  if not session then
    session = setmetatable({ _fibers_search_session = true, state = {} }, Session)
    runtime.stats.search_session_allocations = (runtime.stats.search_session_allocations or 0) + 1
    if instrumentation then
      instrumentation:inc('search_session_allocations')
    end
  end
  local state = session.state or {}
  session.state = state

  state.runtime, state.requests, state.focus = runtime, requests, focus_id
  state.choice_generation = component and component.choice_generation or nil
  state.tasks = arena(state, 'tasks')
  state.root_count, state.root_1, state.root_2 = 0, nil, nil
  state.active = arena(state, 'active')
  state.active_head = 1
  state.roots = arena(state, 'roots')
  state.groups = arena(state, 'groups')
  state.views = arena(state, 'views')
  state.intents = arena(state, 'intents')
  state.intent_by_id = arena(state, 'intent_by_id')
  state.effects = arena(state, 'effects')
  state.negative_checks = arena(state, 'negative_checks')
  state.fallback_interests = arena(state, 'fallback_interests')
  state.excluded_roots = arena(state, 'excluded_roots')
  state.used_fallback = false
  state.next_task, state.next_group, state.next_view, state.next_intent = 0, 0, 0, 0
  state.next_machine_serial, state.search_steps, state.search_depth = 0, 0, 1
  state.search_limit = search_limit or runtime.search_limit
  state.profile_plan = profile_plan
  state.state_memoization_possible = state_memoization_possible or nil
  state.state_memoization_min_steps = state_memoization_possible
      and (policy and policy.state_min_steps or runtime.state_memoization_min_steps)
    or nil
  state.refutation_cache_possible = refutation_cache_possible or nil
  state.refutation_cache_min_steps = refutation_cache_possible
      and (policy and policy.supplier_min_steps or runtime.refutation_cache_min_steps)
    or nil
  state.component = (state_memoization_possible or refutation_cache_possible) and component or nil
  state.plan_id = (state_memoization_possible or refutation_cache_possible) and runtime.stats.plans or nil
  state.search_cache = nil

  session._fibers_search_session = true
  session.runtime = runtime
  session.instrumentation = instrumentation
  session.profile_plan = profile_plan
  session.phase = 'enter'
  session.memo_signature = nil
  session.stack = nil
  session.finished = false
  session.disposed = false
  session.pooled = false
  session.result_kind = nil
  session.result_candidate = nil
  session.result_refutation = nil
  session.active_elapsed = 0
  session.work_remaining = nil
  session.suspensions = nil
  session:clear_hit()

  state.session = session
  return session
end

function Session:reuse_array(name)
  local values = self[name]
  if not values then
    values = {}
    self[name] = values
  else
    clear_table(values)
  end
  return values
end

function Session:frontier_scratch()
  local scratch = self._frontier_scratch
  if not scratch then
    scratch = Frontier.new_scratch()
    self._frontier_scratch = scratch
  end
  return scratch
end

-- Result packs are consumed synchronously while the successful session remains
-- alive through commit.  Reusing them therefore removes a common one-value
-- allocation without exposing mutable packs outside the transaction boundary.
function Session:pack(...)
  local n = select('#', ...)
  if n == 0 then
    return Op._pack()
  end
  if not self.runtime.record_pool then
    return Op._pack(...)
  end
  local pool = self._pack_pool
  if not pool then
    pool = {}
    self._pack_pool = pool
  end
  local count = #pool
  local packed
  if count > 0 then
    packed = pool[count]
    pool[count] = nil
  else
    packed = {}
  end
  packed._fibers_pack, packed.n = true, n
  for i = 1, n do
    packed[i] = select(i, ...)
  end
  local active = self._active_packs
  if not active then
    active = {}
    self._active_packs = active
  end
  active[#active + 1] = packed
  return packed
end

function Session:_recycle_packs()
  if not self.runtime.record_pool then
    return
  end
  local active = self._active_packs
  if not active then
    return
  end
  local pool = self._pack_pool
  for i = 1, #active do
    local packed = active[i]
    active[i] = nil
    if packed._fibers_pack_escaped then
      -- Product rows expose lane packs as part of the public result value.  The
      -- session must release its reference without clearing or pooling them.
      packed._fibers_pack_escaped = nil
    else
      clear_table(packed)
      packed._fibers_pack, packed.n = true, 0
      pool[#pool + 1] = packed
    end
  end
end

function Session:set_hit(
  focus,
  participant_count,
  participant_1,
  participant_2,
  participants,
  store_view,
  observations,
  writes,
  effects,
  negative_guard,
  epoch,
  pending_generation,
  negative_checks,
  fallback_interests,
  search_steps
)
  self._fibers_session_hit = true
  self.focus = focus
  self.participant_count = participant_count
  self.participant_1 = participant_1
  self.participant_2 = participant_2
  self.participants = participants
  self.store_view = store_view
  self.observations = observations
  self.writes = writes
  self.effects = effects
  self.negative_guard = negative_guard
  self.epoch = epoch
  self.pending_generation = pending_generation
  self.negative_checks = negative_checks
  self.fallback_interests = fallback_interests
  self.search_steps = search_steps
  self.prepared_effects = nil
  return self
end

function Session:add_hit_effects(extra)
  if not extra or #extra == 0 then
    return self
  end
  local combined = {}
  for i = 1, #(self.effects or {}) do
    combined[#combined + 1] = self.effects[i]
  end
  for i = 1, #extra do
    combined[#combined + 1] = extra[i]
  end
  self.effects = combined
  self.prepared_effects = nil
  return self
end

function Session:outcome_for(request_id)
  local state = self.state
  if not state then
    return nil
  end
  local root = state.root_1
  if root and root.root_id == request_id then
    return root.outcome
  end
  root = state.root_2
  if root and root.root_id == request_id then
    return root.outcome
  end
  root = state.roots and state.roots[request_id]
  return root and root.outcome or nil
end

function Session:clear_hit()
  self._fibers_session_hit = nil
  self.focus = nil
  self.participants = nil
  self.store_view = nil
  self.participant_count = nil
  self.participant_1 = nil
  self.participant_2 = nil
  self.observations = nil
  self.writes = nil
  self.effects = nil
  self.negative_guard = nil
  self.epoch = nil
  self.pending_generation = nil
  self.negative_checks = nil
  self.fallback_interests = nil
  self.search_steps = nil
  self.prepared_effects = nil
end

function Session:_finish(candidate, refutation, outcome)
  if candidate then
    self.runtime._last_search_steps = candidate.search_steps
  end
  if self.state.plan_id then
    SearchCache.finish(self.state)
  end
  if self.profile_plan then
    self.profile_plan.search_steps = self.state.search_steps
    -- Exclude time spent parked between driver calls from search CPU timing.
    self.profile_plan.started = self.instrumentation.clock() - (self.active_elapsed or 0)
    self.instrumentation:finish_plan(self.profile_plan, outcome)
  end
  self.finished = true
  return candidate, refutation, false
end

function Session:advance(max_work)
  if self.finished then
    error('SearchSession has already finished', 2)
  end
  self.work_remaining = math.max(0, math.floor(max_work or self.runtime.search_limit))
  local started = self.instrumentation and self.instrumentation.clock() or nil
  local candidate, refutation, unknown = self.machine.advance(self)
  if started then
    self.active_elapsed = (self.active_elapsed or 0) + (self.instrumentation.clock() - started)
  end
  if unknown then
    self.suspensions = (self.suspensions or 0) + 1
    if self.instrumentation then
      self.instrumentation:inc('search_session_suspensions')
    end
    return nil, refutation, true
  end
  return self:_finish(candidate, refutation, candidate and 'found' or 'retry')
end

function Session:should_retain_retry(component)
  local policy = self.runtime and self.runtime.search_policy
  if policy then
    return policy:retry_candidate(self, component)
  end
  if self.disposed or not self.finished or self.result_kind ~= 'retry' then
    return false
  end
  local state = self.state
  local size = component and component.size or 1
  if size >= 8 or (state.search_steps or 0) >= 8 then
    return true
  end
  local intents = state.intents or {}
  return #intents == 1 and intents[1].kind == 'exchange'
end

function Session:can_reopen_retry()
  if self.disposed or not self.finished or self.result_kind ~= 'retry' or self.stack ~= nil then
    return false
  end
  local state = self.state
  if not state or state.active_head <= #state.active then
    return false
  end
  -- Guard expansions are keyed by semantic activation rather than evaluator
  -- frames.  Rebuild an invalidated residual seed so versioned primitive facts
  -- can select a new activation; unchanged paths still recover their memoised
  -- guard expansion from the request.
  for _, root in pairs(state.roots or {}) do
    local request = root.request
    if request and request.memo and next(request.memo) ~= nil then
      return false
    end
  end
  -- A retained residual seed is presently limited to a genuinely blocked
  -- frontier.  Exhausted structural branches are rebuilt rather than guessed.
  return #(state.intents or {}) > 0
end

function Session:reopen_retry(args)
  if not self:can_reopen_retry() then
    return false
  end
  args = args or {}
  local runtime, state = self.runtime, self.state
  local component = args.component
  local search_limit = args.search_limit
  runtime.stats.plans = runtime.stats.plans + 1
  runtime.stats.residual_seed_reopens = (runtime.stats.residual_seed_reopens or 0) + 1
  if runtime.instrumentation then
    runtime.instrumentation:inc('residual_seed_reopens')
  end

  local pending = map_count(args.requests or state.requests)
  local profile_plan = runtime.instrumentation
      and runtime.instrumentation:begin_plan({
        focus = state.focus,
        pending = pending,
        machine = 'trail',
        total_pending = component and component.total or pending,
        component_size = component and component.size or pending,
        component_dynamic = component and component.dynamic or 0,
        component_global = component and component.global == true or false,
        component_edge_visits = component and component.edge_visits or 0,
      })
    or nil

  state.requests = args.requests or state.requests
  state.choice_generation = component and component.choice_generation or state.choice_generation
  state.component = (state.state_memoization_possible or state.refutation_cache_possible) and component or nil
  state.profile_plan = profile_plan
  state.plan_id = (state.state_memoization_possible or state.refutation_cache_possible)
      and runtime.stats.plans
    or nil
  state.search_cache = state.plan_id and {} or nil
  state.search_steps = 0
  state.search_depth = 1
  state.search_limit = search_limit or runtime.search_limit
  state.excluded_roots = {}
  state.trail:reset()

  self.instrumentation = runtime.instrumentation
  self.profile_plan = profile_plan
  self.active_elapsed = 0
  self.work_remaining = nil
  self.phase = 'reduce'
  self.memo_signature = nil
  self.stack = nil
  self.result_kind = nil
  self.result_candidate = nil
  self.result_refutation = nil
  self.finished = false
  state.session = self
  return true
end

function Session:discard(reason)
  if self.disposed then
    return
  end
  local runtime = self.runtime
  if not self.finished then
    if self.state.plan_id then
      SearchCache.finish(self.state)
    end
    if self.profile_plan then
      self.profile_plan.search_steps = self.state.search_steps
      self.profile_plan.started = self.instrumentation.clock() - (self.active_elapsed or 0)
      self.instrumentation:finish_plan(self.profile_plan, reason or 'invalidated')
    end
  end
  self.finished = true
  self.disposed = true
  self.stack = nil
  if self.stack_arena then
    clear_table(self.stack_arena)
  end
  self.result_candidate = nil
  self.result_refutation = nil
  self.result_kind = nil
  self:clear_hit()

  local state = self.state
  if state then
    state.session = nil
    if state.trail then
      state.trail:reset(runtime and runtime.stats or nil, nil)
    end
    self:_recycle_state_records()
    self:_recycle_packs()
    for i = 1, #STATE_ARENAS do
      local name = STATE_ARENAS[i]
      if state[name] then
        clear_table(state[name])
      end
    end
    state.runtime, state.requests, state.focus, state.choice_generation = nil, nil, nil, nil
    state.root_count, state.root_1, state.root_2 = 0, nil, nil
    state.component, state.profile_plan, state.plan_id = nil, nil, nil
  end
  for i = 1, #SESSION_ARENAS do
    local values = self[SESSION_ARENAS[i]]
    if values then
      clear_table(values)
    end
  end
  if self._frontier_scratch then
    Frontier.clear_scratch(self._frontier_scratch)
  end
  self.profile_plan, self.instrumentation, self.machine = nil, nil, nil
  self.active_elapsed, self.work_remaining = nil, nil
  if runtime then
    runtime:_release_search_session(self)
  end
end

function Session:run_to_completion()
  return self:advance(self.state.search_limit or self.runtime.search_limit)
end

return Session

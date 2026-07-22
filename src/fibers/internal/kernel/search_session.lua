-- Ownership shell for one production-machine proof attempt.
--
-- The session owns one production-machine proof attempt, including its
-- explicit alternative stack.  Search control no longer depends on the Lua
-- call stack; a later driver may therefore retain and resume this object.

local Op = require('fibers.op')
local Ledger = require('fibers.internal.kernel.ledger')

local Session = {}
Session.__index = Session

local STATE_ARENAS = {
  'tasks',
  'active',
  'roots',
  'groups',
  'segments',
  'intents',
  'intent_by_id',
  'effects',
  'negative_checks',
  'fallback_interests',
  'excluded_roots',
}
local SESSION_ARENAS = {
  '_arena_root_segments',
  '_arena_root_ids',
  '_arena_participants',
  '_arena_commit_requests',
  '_arena_commit_outcomes',
}

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

function Session:acquire_record(kind)
  if kind == 'task' then
    return { frames = {} }
  elseif kind == 'segment' then
    return { values = {}, delta = {} }
  elseif kind == 'group' then
    return { lane_segments = {}, lane_outcomes = {} }
  end
  return {}
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

  local profile_plan = instrumentation
      and instrumentation:begin_search_plan(runtime, requests, focus_id, component)
    or nil

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
  state.choice_generation = component and component.order_generation or nil
  state.tasks = arena(state, 'tasks')
  state.root_count, state.root_1, state.root_2 = 0, nil, nil
  state.active = arena(state, 'active')
  state.active_head = 1
  state.roots = arena(state, 'roots')
  state.groups = arena(state, 'groups')
  state.segments = arena(state, 'segments')
  state.intents = arena(state, 'intents')
  state.intent_by_id = arena(state, 'intent_by_id')
  state.effects = arena(state, 'effects')
  state.negative_checks = arena(state, 'negative_checks')
  state.fallback_interests = arena(state, 'fallback_interests')
  state.excluded_roots = arena(state, 'excluded_roots')
  state.used_fallback = false
  state.next_task, state.next_group, state.next_segment, state.next_intent = 0, 0, 0, 0
  state.next_machine_serial, state.search_steps, state.search_depth = 0, 0, 1
  state.search_limit = search_limit or runtime.search_limit
  state.profile_plan = profile_plan
  state.component = component

  session._fibers_search_session = true
  session.runtime = runtime
  session.instrumentation = instrumentation
  session.profile_plan = profile_plan
  session.phase = 'enter'
  session.stack = nil
  session.finished = false
  session.disposed = false
  session.pooled = false
  session.result_kind = nil
  session.result_candidate = nil
  session.result_certificate = nil
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

function Session:pack(...)
  return Op._pack(...)
end

function Session:set_hit(
  focus,
  participant_count,
  participant_1,
  participant_2,
  participants,
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

function Session:_finish(candidate, certificate, outcome)
  if candidate then
    self.runtime._last_search_steps = candidate.search_steps
  end
  if self.profile_plan then
    self.profile_plan.search_steps = self.state.search_steps
    -- Exclude time spent parked between driver calls from search CPU timing.
    self.profile_plan.started = self.instrumentation.clock() - (self.active_elapsed or 0)
    self.instrumentation:finish_plan(self.profile_plan, outcome)
  end
  self.finished = true
  return candidate, certificate, false
end

function Session:advance(max_work)
  if self.finished then
    error('SearchSession has already finished', 2)
  end
  self.work_remaining = math.max(0, math.floor(max_work or self.runtime.search_limit))
  local started = self.instrumentation and self.instrumentation.clock() or nil
  local candidate, certificate, unknown = self.machine.advance(self)
  if started then
    self.active_elapsed = (self.active_elapsed or 0) + (self.instrumentation.clock() - started)
  end
  if unknown then
    self.suspensions = (self.suspensions or 0) + 1
    if self.instrumentation then
      self.instrumentation:inc('search_session_suspensions')
    end
    return nil, certificate, true
  end
  return self:_finish(candidate, certificate, candidate and 'found' or 'retry')
end

function Session:discard(reason)
  if self.disposed then
    return
  end
  local runtime = self.runtime
  if not self.finished then
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
  self.result_certificate = nil
  self.result_kind = nil
  self:clear_hit()

  local state = self.state
  if state then
    Ledger.discard_state(state)
    state.session = nil
    if state.trail then
      state.trail:reset(runtime and runtime.stats or nil, nil)
    end
    for i = 1, #STATE_ARENAS do
      local name = STATE_ARENAS[i]
      if state[name] then
        clear_table(state[name])
      end
    end
    state.runtime, state.requests, state.focus, state.choice_generation = nil, nil, nil, nil
    state.demand_index = nil
    state.root_count, state.root_1, state.root_2 = 0, nil, nil
    state.component, state.profile_plan = nil, nil
  end
  for i = 1, #SESSION_ARENAS do
    local values = self[SESSION_ARENAS[i]]
    if values then
      clear_table(values)
    end
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

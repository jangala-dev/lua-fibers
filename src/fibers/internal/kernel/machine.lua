-- Lazy proof-search machine backed by hierarchical ledger segments.

local Op = require('fibers.op')
local Ledger = require('fibers.internal.kernel.ledger')
local Algebra = require('fibers.internal.kernel.algebra')
local IR = require('fibers.internal.kernel.ir')
local ChoiceOrder = require('fibers.internal.kernel.choice_order')
local Domain = require('fibers.internal.kernel.domain')
local SearchSession = require('fibers.internal.kernel.search_session')
local Path = require('fibers.internal.kernel.path')
local Supply = require('fibers.internal.kernel.supply')
local Certificate = require('fibers.internal.kernel.certificate')
local Trail = require('fibers.internal.kernel.trail')
local extend_scope_path = Path.scope_child

local FULL_SUPPLIER_OPTIONS = { restrict_requests = false, metadata_mode = 'full' }

local M = {}

local unpack_ = table.unpack or unpack
local pack_ = Op._pack
local function programme_kind(program)
  return IR.kind(program)
end
local PACK_TRUE = pack_(true)

local function unpack_pack(p)
  return unpack_(p, 1, p.n or #p)
end

local function packv(state, ...)
  return state.session:pack(...)
end

local function new_outcome(state, packed, wrap, task)
  if task and #task.frames == 0 and state.roots[task.root_id] == task then
    task.pack, task.wrap = packed, wrap
    return task
  end
  local outcome = state.session:acquire_record('outcome')
  outcome.pack, outcome.wrap, outcome.activation = packed, wrap, task and task.activation or nil
  return outcome
end

local function setv(state, target, key, value)
  state.trail:set(target, key, value)
end
local function pushv(state, target, value)
  state.trail:push(target, value)
end

local function object_version_label(value)
  if value == nil then
    return '-'
  end
  return tostring(value.id or value) .. '@' .. tostring(value.version or '')
end

local function advance_activation(state, task, fact)
  setv(state, task, 'activation', Path.child(task.activation, fact))
end

local function intent_activation_label(intent)
  local program = intent.program or {}
  return Path.label(intent.activation) .. '@' .. object_version_label(program.location)
end

local function map_count(xs)
  local n = 0
  for _ in pairs(xs or {}) do
    n = n + 1
  end
  return n
end

local function new_segment(state, root_id, scope_path, source_segment_id)
  state.next_segment = state.next_segment + 1
  local id = state.next_segment
  local source = source_segment_id and state.segments[source_segment_id] or nil
  local segment = state.session:acquire_record('segment')
  setv(state, state.segments, id, Ledger.new_segment(root_id, scope_path, source, id, segment, state))
  local profile_plan = state.profile_plan
  if profile_plan and state.next_segment > profile_plan.max_segments then
    profile_plan.max_segments = state.next_segment
  end
  return id
end

local function ensure_task_segment(state, task)
  local segment_id = task.segment_id
  if segment_id then
    return state.segments[segment_id], segment_id
  end
  segment_id = new_segment(state, task.root_id, task.scope_path or {})
  setv(state, task, 'segment_id', segment_id)
  local root = state.roots[task.root_id]
  if root and root.task_id == task.id and root.segment_id == nil then
    setv(state, root, 'segment_id', segment_id)
  end
  return state.segments[segment_id], segment_id
end

local function join_group_segments(state, group)
  local parent = state.segments[group.parent_segment]
  local children = state.session:reuse_array('_arena_join_children')
  for i = 1, group.count do
    children[i] = state.segments[group.lane_segments[i]]
  end
  return Ledger.join_segments(parent, children, group.mode, state.trail)
end

local function compose_wrap(inner, fn)
  return function(packed)
    if inner then
      packed = inner(packed)
    end
    return pack_(fn(unpack_pack(packed)))
  end
end

local function product_wrap(lane_outcomes)
  local wraps, has_wrap = {}, false
  for i = 1, #lane_outcomes do
    wraps[i] = lane_outcomes[i] and lane_outcomes[i].wrap or false
    if wraps[i] then
      has_wrap = true
    end
  end
  if not has_wrap then
    return nil
  end
  return function(packed)
    local rows = packed[1]
    for i = 1, #wraps do
      if wraps[i] then
        rows[i] = wraps[i](rows[i])
      end
    end
    return pack_(rows)
  end
end

local function add_active(state, task_id)
  local task = state.tasks[task_id]
  setv(state, task, 'status', 'active')
  pushv(state, state.active, task_id)
end

local function add_active_next(state, task_id)
  local task = state.tasks[task_id]
  setv(state, task, 'status', 'active')
  local position = #state.active + 1
  pushv(state, state.active, task_id)
  local head = state.active_head
  if head < position then
    local next_id = state.active[head]
    setv(state, state.active, head, task_id)
    setv(state, state.active, position, next_id)
  end
end

local complete_task
local eliminate_exchange_support
local activate_or_else_fallback

local function finish_group_lane(state, task, frame, outcome)
  local group = state.groups[frame.group_id]
  setv(state, group.lane_outcomes, frame.lane, outcome)
  setv(state, group, 'completed', group.completed + 1)
  setv(state, task, 'status', 'done')

  if group.completed < group.count then
    return true
  end
  if not join_group_segments(state, group) then
    return false
  end

  local rows = { _fibers_rows = true }
  for i = 1, group.count do
    local packed = group.lane_outcomes[i].pack
    packed._fibers_pack_escaped = true
    rows[i] = packed
  end
  local parent = state.tasks[group.parent_task]
  local activation_parts = {}
  for i = 1, group.count do
    activation_parts[i] = Path.label(group.lane_outcomes[i].activation)
  end
  setv(
    state,
    parent,
    'activation',
    Path.child(group.activation, 'product:result:' .. table.concat(activation_parts, ','))
  )
  setv(state, parent, 'status', 'active')
  return complete_task(
    state,
    parent,
    new_outcome(state, packv(state, rows), product_wrap(group.lane_outcomes), parent)
  )
end

local function verify_continuation_dependencies(state, task, frame, next_op)
  if not state.runtime.verify_dependencies or frame.continuation_footprint == nil then
    return
  end
  local declared = IR.metadata_hint(frame.continuation_footprint)
  local actual = IR.metadata(next_op)
  local ok, reason = IR.metadata_covers(declared, actual)
  if not ok then
    local root = task and state.roots[task.root_id]
    local request = root and root.request
    error(
      'continuation dependency declaration is incomplete'
        .. ' in '
        .. tostring(request and request.name or '<unnamed>')
        .. ' ('
        .. tostring(frame.phase or 'and_then')
        .. ', activation='
        .. Path.label(frame.activation)
        .. '): '
        .. tostring(reason),
      0
    )
  end
end

local function evaluate_guard_residual(state, task, guard, activation)
  local request = state.roots[task.root_id].request
  return state.runtime:_guard_residual(request, guard, activation, true)
end

local function preferred_state_for(state, task, activation)
  local key = tostring(task.root_id) .. '@' .. Path.label(activation)
  local states = state.preferred_states
  if not states then
    states = {}
    state.preferred_states = states
  end
  local preferred = states[key]
  if preferred then
    return preferred
  end

  preferred = state.session:acquire_record('preferred_state')
  preferred.phase = 'preferred'
  preferred.evidence = Certificate.local_absence()
  preferred.parent = task.preferred_state

  setv(state, states, key, preferred)
  local profile_plan = state.profile_plan
  if profile_plan then
    profile_plan.preferred_states_opened = (profile_plan.preferred_states_opened or 0) + 1
  end
  return preferred
end

local function report_absence(state, preferred, certificate, source, closed)
  if not preferred or not certificate then
    return certificate
  end
  local merged = Certificate.merge(preferred.evidence, certificate)
  preferred.evidence = merged
  local profile_plan = state.profile_plan
  if profile_plan then
    profile_plan.preferred_state_evidence = (profile_plan.preferred_state_evidence or 0) + 1
    state.runtime.instrumentation:event(profile_plan, 'preferred_state_evidence', {
      source = source or 'unspecified',
      closed = closed == true,
    })
  end
  if not closed or preferred.phase ~= 'preferred' then
    return merged
  end

  preferred.phase = 'closed'
  if profile_plan then
    profile_plan.preferred_states_closed = (profile_plan.preferred_states_closed or 0) + 1
  end
  return merged
end

local function report_task_absence(state, task, certificate, source, closed)
  return report_absence(state, task and task.preferred_state or nil, certificate, source, closed)
end

local function report_intent_absence(state, intents, certificate, source)
  local seen = {}
  for i = 1, #(intents or {}) do
    local task = state.tasks[intents[i].task_id]
    local preferred = task and task.preferred_state or nil
    if preferred and not seen[preferred] then
      seen[preferred] = true
      report_absence(state, preferred, certificate, source, false)
    end
  end
end

local function close_preferred_occurrence(state, frame, certificate, source)
  local closed =
    report_absence(state, frame.preferred, certificate or Certificate.local_absence(), source, true)
  activate_or_else_fallback(
    state,
    state.tasks[frame.task_id],
    frame.expr,
    frame.activation,
    closed,
    frame.preferred,
    frame.parent_preferred
  )
  return closed
end

complete_task = function(state, task, outcome)
  while true do
    local n = #task.frames
    if n == 0 then
      local root = state.roots[task.root_id]
      setv(state, root, 'done', true)
      setv(state, root, 'outcome', outcome)
      setv(state, task, 'status', 'done')
      return true
    end

    local frame = task.frames[n]
    setv(state, task.frames, n, nil)

    if frame.kind == 'bind' then
      if outcome.wrap then
        error('transactional continuation attempted to consume a wrapped result', 0)
      end
      if frame.phase == 'map' then
        -- A map callback has already produced the next completed value.  Keep
        -- unwinding this task directly instead of allocating Op.always and
        -- scheduling another deterministic evaluator step.
        local exchange_support = outcome.exchange_support
        outcome = new_outcome(
          state,
          packv(
            state,
            state.runtime:_call_in_phase('map', 'callback_error', frame.fn, unpack_pack(outcome.pack))
          ),
          nil,
          task
        )
        outcome.exchange_support = exchange_support
      else
        local next_op =
          state.runtime:_call_in_phase('and_then', 'callback_error', frame.fn, unpack_pack(outcome.pack))
        if not Op.is_op(next_op) then
          error('and_then callback must return an Op', 0)
        end
        verify_continuation_dependencies(state, task, frame, next_op)
        if outcome.exchange_support then
          setv(state, task, 'exchange_support_provenance', outcome.exchange_support)
        end
        if next_op.kind == 'choice' and #(next_op.choices or {}) == 0 then
          local failure = Certificate.mark_failure(Certificate.local_absence(), task.id)
          eliminate_exchange_support(state, failure)
        end
        setv(state, task, 'expr', next_op)
        setv(
          state,
          task,
          'activation',
          Path.child(frame.activation, 'and_then:result:' .. Path.label(outcome.activation))
        )
        if task.exchange_support_provenance then
          setv(state, state, 'residual_propagation_required', true)
          add_active_next(state, task.id)
        else
          add_active(state, task.id)
        end
        return true
      end
    elseif frame.kind == 'wrap' then
      outcome.wrap = compose_wrap(outcome.wrap, frame.fn)
    elseif frame.kind == 'symmetry_restore' then
      setv(state, task, 'symmetry_key', frame.previous_symmetry)
    elseif frame.kind == 'group_lane' then
      return finish_group_lane(state, task, frame, outcome)
    else
      error('unknown evaluator frame: ' .. tostring(frame.kind), 0)
    end
  end
end

local function enable_full_dependency_frontier(state)
  local frontier = state.dependency_frontier
  if not frontier then
    frontier = { expanded = false }
    setv(state, state, 'dependency_frontier', frontier)
  end
  return frontier
end

local function mark_dependency_frontier_expanded(state)
  local frontier = state.dependency_frontier
  if frontier and not frontier.expanded then
    setv(state, frontier, 'expanded', true)
  end
end

local function add_root(state, root_id)
  if state.roots[root_id] then
    return
  end
  local request = state.requests[root_id]
  if not request then
    request = state.runtime.pending_by_id[root_id]
    if request then
      setv(state, state.requests, root_id, request)
      mark_dependency_frontier_expanded(state)
    end
  end
  if not request then
    return
  end
  if not request.activation_root then
    request.activation_root = Path.new_request(request.id or root_id)
  end

  state.next_task = state.next_task + 1
  local task_id = state.next_task
  -- The root and its initial evaluator task have identical lifetimes and no
  -- conflicting fields.  Use one strand record for both roles; product lanes
  -- and other child tasks remain ordinary task records.
  local task = state.session:acquire_record('task')
  task.id, task.root_id, task.expr = task_id, root_id, request.op
  task.activation = request.activation_root
  task.segment_id, task.scope_path, task.status = nil, nil, 'active'
  task.choice_serial, task.symmetry_key, task.preferred_state = 0, nil, nil
  task.request, task.task_id, task.done, task.outcome = request, task_id, false, nil
  setv(state, state.tasks, task_id, task)
  setv(state, state.roots, root_id, task)
  local root_count = state.root_count + 1
  setv(state, state, 'root_count', root_count)
  if root_count == 1 then
    setv(state, state, 'root_1', task)
  elseif root_count == 2 then
    setv(state, state, 'root_2', task)
  end
  pushv(state, state.active, task_id)
  local profile_plan = state.profile_plan
  if profile_plan then
    local active, roots = #state.active - state.active_head + 1, map_count(state.roots)
    if roots > profile_plan.max_roots then
      profile_plan.max_roots = roots
    end
    if state.next_task > profile_plan.max_tasks then
      profile_plan.max_tasks = state.next_task
    end
    if active > profile_plan.max_active then
      profile_plan.max_active = active
    end
  end
end

local function start_product(state, task, op)
  state.next_group = state.next_group + 1
  local group_id = state.next_group
  local group = state.session:acquire_record('group')
  local _, parent_segment_id = ensure_task_segment(state, task)
  group.id, group.parent_task, group.parent_segment = group_id, task.id, parent_segment_id
  group.activation = task.activation
  group.mode, group.count, group.completed = op.mode, #op.lanes, 0
  setv(state, state.groups, group_id, group)
  setv(state, task, 'status', 'waiting_group')

  local profile_plan = state.profile_plan
  if profile_plan then
    state.runtime.instrumentation:event(profile_plan, 'product', { mode = op.mode, lanes = #op.lanes })
  end
  for i = 1, #op.lanes do
    local path = extend_scope_path(task.scope_path, group_id, op.mode, i)
    local segment_id = new_segment(state, task.root_id, path, parent_segment_id)
    setv(state, group.lane_segments, i, segment_id)
    state.next_task = state.next_task + 1
    local child_id = state.next_task
    local child = state.session:acquire_record('task')
    child.id, child.root_id, child.expr = child_id, task.root_id, op.lanes[i]
    child.activation = Path.child(task.activation, 'product:lane:' .. tostring(i))
    child.frames[1] = { kind = 'group_lane', group_id = group_id, lane = i }
    child.segment_id, child.scope_path, child.status = segment_id, path, 'active'
    child.choice_serial, child.symmetry_key = 0, task.symmetry_key
    child.preferred_state = task.preferred_state
    setv(state, state.tasks, child_id, child)
    pushv(state, state.active, child_id)
  end
  if profile_plan then
    local active = #state.active - state.active_head + 1
    if state.next_task > profile_plan.max_tasks then
      profile_plan.max_tasks = state.next_task
    end
    if active > profile_plan.max_active then
      profile_plan.max_active = active
    end
  end
end

local function same_root_compatible(a, b)
  return Path.relation(a.root_id, a.scope_path, b.root_id, b.scope_path) == 'interacting'
end

local function exchange_support_key(a, b)
  local left, right = Path.label(a.activation), Path.label(b.activation)
  if right < left then
    left, right = right, left
  end
  return 'exchange:' .. tostring(a.resource) .. ':' .. left .. '<->' .. right
end

local function intents_compatible(a, b)
  if a.kind ~= 'exchange' or b.kind ~= 'exchange' then
    return false
  end
  if a.resource ~= b.resource or a.role == b.role then
    return false
  end
  return a.root_id ~= b.root_id or same_root_compatible(a, b)
end

local function compatibility_fn(state)
  local eliminated = state.session.support_eliminations
  if not eliminated then
    return intents_compatible
  end
  local fn = state._intents_compatible
  if not fn then
    fn = function(a, b)
      if not intents_compatible(a, b) then
        return false
      end
      if eliminated[exchange_support_key(a, b)] then
        local profile_plan = state.profile_plan
        if profile_plan then
          profile_plan.exchange_support_eliminations_pruned = (
            profile_plan.exchange_support_eliminations_pruned or 0
          ) + 1
        end
        return false
      end
      return true
    end
    state._intents_compatible = fn
  end
  return fn
end

eliminate_exchange_support = function(state, certificate)
  local task_id = Certificate.local_failure_task(certificate)
  local task = task_id and state.tasks[task_id] or nil
  local pair = task and task.exchange_support_provenance or nil
  if not pair then
    return false
  end
  local eliminated = state.session.support_eliminations
  if not eliminated then
    eliminated = {}
    state.session.support_eliminations = eliminated
  end
  if eliminated[pair] then
    return false
  end
  eliminated[pair] = true
  report_task_absence(state, task, certificate, 'exchange_support', false)
  state._intents_compatible = nil
  local profile_plan = state.profile_plan
  if profile_plan then
    profile_plan.exchange_support_eliminations_learned = (
      profile_plan.exchange_support_eliminations_learned or 0
    ) + 1
  end
  return true
end

local function remove_intent_ids(state, ids)
  local remove = {}
  for i = 1, #ids do
    local id = ids[i]
    local intent = state.intent_by_id[id]
    remove[id] = true
    if intent and state.demand_index then
      Domain.remove(state.demand_index, intent, state.trail)
    end
    setv(state, state.intent_by_id, id, nil)
  end
  local kept = {}
  for i = 1, #state.intents do
    if not remove[state.intents[i].id] then
      kept[#kept + 1] = state.intents[i]
    end
  end
  setv(state, state, 'intents', kept)
end

local function block_intent(state, task, occurrence)
  local program = occurrence.program
  state.next_intent = state.next_intent + 1
  setv(state, task, 'status', 'blocked')
  local intent = state.session:acquire_record('intent')
  intent.id, intent.kind = state.next_intent, programme_kind(program)
  intent.task_id, intent.root_id, intent.program = task.id, task.root_id, program
  intent.payload = occurrence.payload
  intent.activation = task.activation
  intent.resource, intent.role = program.resource, program.role
  intent.value = occurrence.value
  intent.symmetry_key, intent.scope_path = task.symmetry_key, task.scope_path
  intent.interest = type(program.interest) == 'function' and program.interest(state.runtime, program)
    or program.interest
  intent.absence_check = program.absence_check
  pushv(state, state.intents, intent)
  setv(state, state.intent_by_id, intent.id, intent)
  local demand_index = state.demand_index
  if demand_index then
    Domain.add(demand_index, intent, state.trail)
  elseif #state.intents > Domain.SMALL_LIMIT then
    demand_index = Domain.new(state.runtime)
    setv(state, state, 'demand_index', demand_index)
    for i = 1, #state.intents do
      Domain.add(demand_index, state.intents[i], state.trail)
    end
  end
  local profile_plan = state.profile_plan
  if profile_plan then
    if #state.intents > profile_plan.max_intents then
      profile_plan.max_intents = #state.intents
    end
    state.runtime.instrumentation:event(profile_plan, 'intent', {
      primitive_kind = IR.kind(program),
      role = program.role,
      resource = tostring(program.resource),
    })
  end
end
local function task_has_transactional_continuation(task)
  for i = #task.frames, 1, -1 do
    local frame = task.frames[i]
    if frame.kind == 'bind' then
      return frame.phase ~= 'map'
    elseif frame.kind == 'group_lane' then
      return false
    end
  end
  return false
end

local function match_intents(state, left_id, right_id)
  local a, b = state.intent_by_id[left_id], state.intent_by_id[right_id]
  if not a or not b then
    return false
  end
  remove_intent_ids(state, { left_id, right_id })
  local put = a.role == 'put' and a or b
  local get = a.role == 'get' and a or b
  local put_task = state.tasks[put.task_id]
  local get_task = state.tasks[get.task_id]
  local support_key = task_has_transactional_continuation(get_task) and exchange_support_key(a, b) or nil
  local labels = { Path.label(a.activation), Path.label(b.activation) }
  table.sort(labels)
  local fact = 'exchange:' .. table.concat(labels, '+')
  setv(state, put_task, 'activation', Path.child(put_task.activation, fact))
  setv(state, get_task, 'activation', Path.child(get_task.activation, fact))
  if not complete_task(state, put_task, new_outcome(state, PACK_TRUE, nil, put_task)) then
    return false
  end
  local get_outcome = new_outcome(state, packv(state, put.value), nil, get_task)
  if support_key then
    get_outcome.exchange_support = support_key
  end
  if not complete_task(state, get_task, get_outcome) then
    return false
  end
  return true
end

local function transition_context(state)
  local context = state.transition_context
  if not context then
    context = {
      runtime = state.runtime,
      now = function()
        return state.runtime:now()
      end,
    }
    state.transition_context = context
  end
  return context
end

local function transition_ready(state, program, value, payload)
  local plan = state.profile_plan
  if plan then
    plan.machine_probes = plan.machine_probes + 1
  end
  return IR.transition_ready(program, value, transition_context(state), payload)
end

local function transition_outcome(state, program, value, phase, payload)
  local plan = state.profile_plan
  if plan and IR.rule(program).serial then
    plan.machine_steps = plan.machine_steps + 1
  end
  return IR.transition_cursor(program, value, transition_context(state), phase, payload):next()
end

local function stage_outcome(state, task, program, outcome)
  local patch
  if outcome.writes then
    if outcome.machine then
      state.next_machine_serial = state.next_machine_serial + 1
    end
    patch = IR.transition_patch(program, outcome, state.next_machine_serial)
  end
  if patch then
    Ledger.stage(state.segments[task.segment_id], program.location, patch, state.trail)
  else
    Ledger.observe(state.segments[task.segment_id], program.location, state.trail)
  end
end

local function activation_fact(selected)
  local labels = {}
  for i = 1, #selected do
    labels[i] = intent_activation_label(selected[i])
  end
  table.sort(labels)
  return 'transition:' .. table.concat(labels, '+')
end

local function finish_transitions(state, selected, resolved)
  local ids, fact = {}, activation_fact(selected)
  for i = 1, #selected do
    ids[i] = selected[i].id
  end
  remove_intent_ids(state, ids)
  for i = 1, #resolved do
    local row = resolved[i]
    setv(state, row.task, 'activation', Path.child(row.task.activation, fact))
    if not complete_task(state, row.task, new_outcome(state, row.result, nil, row.task)) then
      return false
    end
  end
  return true
end

local function resolve_serial_transitions(state, selected)
  table.sort(selected, function(left, right)
    local a, b = IR.rule(left.program).order, IR.rule(right.program).order
    return a ~= b and a < b or a == b and (left.id or 0) < (right.id or 0)
  end)
  local resolved = {}
  for i = 1, #selected do
    local intent, program = selected[i], selected[i].program
    local task, rule = state.tasks[intent.task_id], IR.rule(program)
    ensure_task_segment(state, task)
    local value = Ledger.project_machine(state, task, program.location, function(candidate)
      return transition_ready(state, program, candidate, intent.payload)
    end, rule.accepts_supply, state.trail)
    local outcome = transition_outcome(state, program, value, nil, intent.payload)
    if not outcome then
      return false
    end
    stage_outcome(state, task, program, outcome)
    resolved[#resolved + 1] = { task = task, result = outcome.result }
  end
  return finish_transitions(state, selected, resolved)
end

local function selected_intents(state, ids)
  local wanted, selected = {}, {}
  for i = 1, #ids do
    wanted[ids[i]] = true
  end
  for i = 1, #state.intents do
    local intent = state.intents[i]
    if wanted[intent.id] then
      selected[#selected + 1] = intent
    end
  end
  table.sort(selected, function(a, b)
    return a.id < b.id
  end)
  return selected
end

local function resolve_transitions(state, intent_ids)
  local selected = selected_intents(state, intent_ids)
  if #selected == 0 then
    return false
  end
  if IR.rule(selected[1].program).serial then
    return resolve_serial_transitions(state, selected)
  end

  local resolved, remaining = {}, {}
  for i = 1, #selected do
    remaining[i] = selected[i]
  end
  while #remaining > 0 do
    local chosen_index, chosen_outcome, chosen_task
    for i = 1, #remaining do
      local intent, program = remaining[i], remaining[i].program
      local task = state.tasks[intent.task_id]
      ensure_task_segment(state, task)
      local value = Ledger.project(state, task, program.location, program.orientation, state.trail)
      if value ~= nil then
        local outcome = transition_outcome(state, program, value, nil, intent.payload)
        if outcome then
          chosen_index, chosen_outcome, chosen_task = i, outcome, task
          break
        end
      end
    end
    if not chosen_index then
      return false
    end
    local intent = remaining[chosen_index]
    stage_outcome(state, chosen_task, intent.program, chosen_outcome)
    resolved[#resolved + 1] = { task = chosen_task, result = chosen_outcome.result }
    table.remove(remaining, chosen_index)
  end
  return finish_transitions(state, selected, resolved)
end

local function witness_cursor(state, intent)
  local program, task, rule = intent.program, state.tasks[intent.task_id], IR.rule(intent.program)
  ensure_task_segment(state, task)
  local value = Ledger.project_machine(state, task, program.location, function(candidate)
    return transition_ready(state, program, candidate, intent.payload)
  end, rule.accepts_supply, state.trail)
  return IR.transition_cursor(program, value, transition_context(state), nil, intent.payload)
end

local function resolve_witness(state, intent_id, outcome, alternative_index)
  local intent = state.intent_by_id[intent_id]
  if not intent or not outcome then
    return false
  end
  local task = state.tasks[intent.task_id]
  stage_outcome(state, task, intent.program, outcome)
  remove_intent_ids(state, { intent_id })
  setv(
    state,
    task,
    'activation',
    Path.child(
      task.activation,
      'witness:' .. intent_activation_label(intent) .. ':' .. tostring(alternative_index or 1)
    )
  )
  local packed = outcome.result
  if not (type(packed) == 'table' and packed._fibers_pack == true) then
    if type(packed) == 'table' and packed.n ~= nil then
      packed._fibers_pack = true
    else
      packed = packv(state, packed)
    end
  end
  return complete_task(state, task, new_outcome(state, packed, nil, task))
end

local function resolve_transition_set(state, group, ids)
  local selected = {}
  for i = 1, #ids do
    selected[ids[i]] = true
  end
  for i = 1, #(group.ids or {}) do
    local id, intent = group.ids[i], state.intent_by_id[group.ids[i]]
    local rule = intent and IR.rule(intent.program)
    if rule and rule.serial and rule.total then
      selected[id] = true
    end
  end
  local expanded = {}
  for id in pairs(selected) do
    expanded[#expanded + 1] = id
  end
  table.sort(expanded)
  return resolve_transitions(state, expanded)
end

local function final_candidate(state)
  local root_count = state.root_count or 0
  local root_ids
  if root_count <= 2 then
    if (state.root_1 and not state.root_1.done) or (state.root_2 and not state.root_2.done) then
      return nil
    end
  else
    root_ids = state.session:reuse_array('_arena_root_ids')
    for id in pairs(state.roots) do
      root_ids[#root_ids + 1] = id
    end
    table.sort(root_ids)
    for i = 1, #root_ids do
      if not state.roots[root_ids[i]].done then
        return nil
      end
    end
  end
  if #state.intents > 0 then
    return nil
  end

  local root_segments = state.session:reuse_array('_arena_root_segments')
  if root_count <= 2 then
    local root = state.root_1
    if root and root.segment_id then
      root_segments[#root_segments + 1] = state.segments[root.segment_id]
    end
    root = state.root_2
    if root and root.segment_id then
      root_segments[#root_segments + 1] = state.segments[root.segment_id]
    end
  else
    for i = 1, #root_ids do
      local root = state.roots[root_ids[i]]
      if root.segment_id then
        root_segments[#root_segments + 1] = state.segments[root.segment_id]
      end
    end
  end
  local observations, writes, collect_err = Ledger.collect_candidate(root_segments)
  if collect_err then
    return nil
  end

  -- Domain constraints are fixed substrate rules, not resource callbacks.
  local domain_writes = writes
  for loc, patch in pairs(domain_writes or {}) do
    if loc.domain == 'counter' then
      local final = Algebra.apply(loc, loc.value, patch)
      local owner = loc.owner
      if owner.min ~= nil and final < owner.min then
        return nil
      end
      if owner.max ~= nil and final > owner.max then
        return nil
      end
    end
  end

  local participant_count = root_count
  local participant_1 = state.root_1 and state.root_1.root_id or nil
  local participant_2 = state.root_2 and state.root_2.root_id or nil
  local participants = nil
  if root_count > 2 then
    participants = state.session:reuse_array('_arena_participants')
    for i = 1, #root_ids do
      participants[i] = root_ids[i]
    end
    participant_1, participant_2 = nil, nil
  elseif participant_count == 2 and participant_2 < participant_1 then
    participant_1, participant_2 = participant_2, participant_1
  end

  local absence_gate = Certificate.stamp_absence_gate(state.absence_gate, state.runtime)

  -- One- and two-party hits remain inline.  The general participant array is
  -- promoted only when a transaction actually contains more than two roots.
  local candidate = state.session:set_hit(
    state.focus,
    participant_count,
    participant_1,
    participant_2,
    participants,
    observations,
    writes,
    #state.effects > 0 and state.effects or nil,
    absence_gate,
    state.search_steps
  )

  -- Effect merge and pure preparation are part of world admissibility. Search
  -- may repeat or discard preparation freely. A structured refusal rejects this
  -- derivation and lets ordinary search backtrack to another world; irreversible
  -- work is confined to discharge after state installation.
  local prepared = state.runtime:_prepare_hit_effects(candidate)
  if not prepared then
    candidate:clear_hit()
    return nil
  end
  candidate.prepared_effects = prepared
  local plan = state.profile_plan
  if plan then
    plan.participants = participant_count
    plan.observations = map_count(observations)
    plan.writes = map_count(writes)
    plan.effects = #(candidate.effects or {})
  end
  return candidate
end

local function execute_program(state, task, occurrence)
  local program = occurrence.program
  if not program or program._fibers_program ~= true then
    error('primitive payload is not a kernel programme', 0)
  end

  local kind = programme_kind(program)
  if kind == 'exchange' then
    block_intent(state, task, occurrence)
    return true
  end

  if kind == 'observe' then
    local resource = program.resource
    local segment = ensure_task_segment(state, task)
    local value = program.observation.collect(resource, function(location)
      return Ledger.read(segment, location, state.trail)
    end)
    advance_activation(state, task, 'primitive:observe:' .. object_version_label(resource))
    return complete_task(
      state,
      task,
      new_outcome(state, IR.result_pack(program, value, state.session), nil, task)
    )
  end

  local segment = nil
  local loc = program.location

  if kind == 'version_wait' then
    segment = ensure_task_segment(state, task)
    local version = occurrence.version
    if loc.version ~= version then
      Ledger.observe(segment, loc, state.trail)
      advance_activation(state, task, 'primitive:version_wait:' .. object_version_label(loc))
      return complete_task(
        state,
        task,
        new_outcome(state, packv(state, Ledger.read(segment, loc, state.trail), loc.version), nil, task)
      )
    end
    program.observed_version = loc.version
    block_intent(state, task, occurrence)
    return true
  end

  if kind == 'read' then
    segment = ensure_task_segment(state, task)
    advance_activation(state, task, 'primitive:read:' .. object_version_label(loc))
    return complete_task(
      state,
      task,
      new_outcome(
        state,
        IR.result_pack(program, Ledger.read(segment, loc, state.trail), state.session),
        nil,
        task
      )
    )
  end

  if kind == 'patch' then
    segment = ensure_task_segment(state, task)
    local patch = occurrence.patch
    Ledger.stage(segment, loc, patch, state.trail)
    advance_activation(state, task, 'primitive:patch:' .. object_version_label(loc))
    return complete_task(
      state,
      task,
      new_outcome(
        state,
        IR.result_pack(program, Ledger.read(segment, loc, state.trail), state.session),
        nil,
        task
      )
    )
  end

  if kind == 'transition' then
    local rule = IR.rule(program)
    if rule.eager then
      segment = ensure_task_segment(state, task)
      local value = Ledger.read(segment, loc, state.trail)
      local outcome = transition_outcome(state, program, value, 'eager', occurrence.payload)
      if outcome then
        stage_outcome(state, task, program, outcome)
        advance_activation(state, task, 'primitive:transition:' .. object_version_label(loc))
        return complete_task(state, task, new_outcome(state, outcome.result, nil, task))
      end
    end
    block_intent(state, task, occurrence)
    return true
  end

  error('unknown programme kind: ' .. tostring(kind), 0)
end

local function has_supplier(state, intents, required_certainty)
  local frontier = state.dependency_frontier
  if frontier then
    mark_dependency_frontier_expanded(state)
    return state.runtime:_has_supplier(
      intents,
      state.roots,
      state.excluded_roots,
      state.runtime.pending_by_id,
      required_certainty,
      FULL_SUPPLIER_OPTIONS
    )
  end
  return state.runtime:_has_supplier(
    intents,
    state.roots,
    state.excluded_roots,
    state.requests,
    required_certainty
  )
end

local function supplier_candidate(state)
  local frontier = state.dependency_frontier
  if frontier then
    mark_dependency_frontier_expanded(state)
    return state.runtime:_supplier_request(
      state.intents,
      state.roots,
      state.excluded_roots,
      state.runtime.pending_by_id,
      FULL_SUPPLIER_OPTIONS
    )
  end
  return state.runtime:_supplier_request(state.intents, state.roots, state.excluded_roots, state.requests)
end

local function terminal_certificate(state)
  return Certificate.from_intents(state.intents)
end

local function collect_defeat_effects(expr, out)
  out = out or {}
  if not expr then
    return out
  end
  local kind = expr.kind
  if kind == 'annotated' then
    for i = 1, #(expr.defeats or {}) do
      out[#out + 1] = expr.defeats[i]
    end
    return collect_defeat_effects(expr.p, out)
  elseif kind == 'product' then
    for i = 1, #(expr.lanes or {}) do
      collect_defeat_effects(expr.lanes[i], out)
    end
  elseif kind == 'choice' then
    for i = 1, #(expr.choices or {}) do
      collect_defeat_effects(expr.choices[i], out)
    end
  elseif kind == 'or_else' then
    -- The preferred occurrence is entered immediately; fallback is residual
    -- and does not become entered unless preferred retry is certified.
    collect_defeat_effects(expr.p, out)
  elseif kind == 'and_then' then
    -- Only the prefix is entered before its result constructs the continuation.
    collect_defeat_effects(expr.p, out)
  end
  return out
end

local function attach_candidate_effects(runtime, candidate, extra)
  if #extra == 0 then
    return candidate
  end
  if candidate._fibers_session_hit then
    candidate:add_hit_effects(extra)
  else
    candidate.effects = candidate.effects or {}
    for i = 1, #extra do
      candidate.effects[#candidate.effects + 1] = extra[i]
    end
  end
  local prepared = runtime:_prepare_hit_effects(candidate)
  if not prepared then
    if candidate._fibers_session_hit then
      candidate:clear_hit()
    end
    return nil
  end
  candidate.prepared_effects = prepared
  return candidate
end

local function stop_search(state, reason, hard)
  local session = state.session
  if session then
    session.unknown_reason = reason
    session.hard_limit = hard == true
  end
  return false
end

local function begin_search_round(state)
  local session = state.session
  if state.runtime._cycle_budget and not state.runtime:_charge_cycle_work(1) then
    return stop_search(state, 'cycle_work_limit', false)
  end
  local limits = state.search_limits
  if limits then
    if limits.total and state.search_steps >= limits.total then
      return stop_search(state, 'search_total_limit', true)
    end
    if limits.depth and state.search_depth > limits.depth then
      return stop_search(state, 'search_depth_limit', true)
    end
    if limits.trail and state.trail and state.trail.n > limits.trail then
      return stop_search(state, 'search_trail_limit', true)
    end
  end
  if session and session.work_remaining ~= nil then
    if session.work_remaining <= 0 then
      return stop_search(state, 'search_quantum', false)
    end
    session.work_remaining = session.work_remaining - 1
  elseif state.search_steps >= state.search_limit then
    return stop_search(state, 'search_quantum', false)
  end
  if session then
    session.unknown_reason = nil
    session.hard_limit = false
  end

  state.runtime.stats.search_calls = state.runtime.stats.search_calls + 1
  local profile_plan = state.profile_plan
  state.search_steps = state.search_steps + 1
  if profile_plan then
    profile_plan.search_calls = profile_plan.search_calls + 1
    local active, intents = #state.active - state.active_head + 1, #state.intents
    if active > profile_plan.max_active then
      profile_plan.max_active = active
    end
    if intents > profile_plan.max_intents then
      profile_plan.max_intents = intents
    end
  end
  return true
end

-- Pick deterministic evaluator work ahead of unresolved search branches.  A
-- selected choice commonly exposes a resource constraint which can prune the
-- remaining choices; processing another syntactic choice first hides that
-- information and constructs an avoidably broad Cartesian search.
--
-- The common path remains O(1): when the queue head is deterministic it is
-- returned immediately.  We scan only when the head itself is a branch.
local function metadata_has_exchange(metadata)
  return metadata and next(metadata.exchanges or {}) ~= nil
end

local RESIDUAL_STATIC = 0
local RESIDUAL_REVEALED = 1
local RESIDUAL_UNOPENED = 2

local function residual_child(activation, label)
  return activation and Path.child(activation, label) or nil
end

-- Outcome-only wrappers preserve blocking shape. This is the sole traversal
-- used by supplier analysis, guard scheduling and raw-exchange pruning.
local function inspect_transparent_residual(state, task, activation, op)
  while op do
    if op.kind == 'guard' then
      local root = state and task and state.roots[task.root_id] or nil
      local request = root and root.request or nil
      local cached = request and activation and request.guard_residuals[activation] or nil
      if cached then
        return cached, activation, RESIDUAL_REVEALED
      end
      return op, activation, RESIDUAL_UNOPENED, op
    elseif op.kind == 'annotated' then
      activation = residual_child(activation, 'annotated:body')
      op = op.p
    elseif op.kind == 'and_then' and op.derived_map then
      activation = residual_child(activation, 'and_then:prefix')
      op = op.p
    else
      return op, activation, RESIDUAL_STATIC
    end
  end
  return nil, activation, RESIDUAL_STATIC
end

local function choice_candidate(task, expr, activation, choice_index)
  return {
    task_id = task.id,
    expr = expr,
    choice_index = choice_index,
    activation = activation,
  }
end

local function analyse_dynamic_choice_supply(state, task, expr, activation, intents)
  local alternatives = {}
  local analysis = {
    task = task,
    expr = expr,
    activation = activation,
    size = #(expr.choices or {}),
    dynamic = true,
    exact_score = 0,
    opaque_score = 0,
    exact_candidates = {},
    has_revealed_guard = false,
  }

  for ai = 1, analysis.size do
    local alternative = expr.choices[ai]
    local alternative_activation = Path.child(activation, 'choice:' .. tostring(ai))
    local residual, guard_activation, residual_state, guard =
      inspect_transparent_residual(state, task, alternative_activation, alternative)
    alternatives[ai] = {
      metadata = IR.active_metadata(residual),
      residual_state = residual_state,
    }
    if residual_state == RESIDUAL_UNOPENED and analysis.probe == nil then
      analysis.probe = {
        task = task,
        guard = guard,
        activation = guard_activation,
      }
    end
  end

  local exact_by_intent, opaque_by_intent = {}, {}
  for ai = 1, analysis.size do
    local row = alternatives[ai]
    local supplies_exact = false
    for ii = 1, #intents do
      local certainty = IR.supply_relation(row.metadata, intents[ii])
      if certainty == IR.SUPPLY_EXACT then
        exact_by_intent[ii] = true
        supplies_exact = true
      elseif certainty == IR.SUPPLY_OPAQUE then
        opaque_by_intent[ii] = true
      end
    end
    if supplies_exact then
      analysis.exact_candidates[#analysis.exact_candidates + 1] = choice_candidate(task, expr, activation, ai)
      if row.residual_state == RESIDUAL_REVEALED then
        analysis.has_revealed_guard = true
      end
    end
  end

  for ii = 1, #intents do
    if exact_by_intent[ii] then
      analysis.exact_score = analysis.exact_score + 1
    elseif opaque_by_intent[ii] then
      analysis.opaque_score = analysis.opaque_score + 1
    end
  end
  if analysis.exact_score > 0 then
    analysis.certainty = IR.SUPPLY_EXACT
    analysis.score = analysis.exact_score
  elseif analysis.opaque_score > 0 then
    analysis.certainty = IR.SUPPLY_OPAQUE
    analysis.score = analysis.opaque_score
  else
    analysis.certainty = IR.SUPPLY_NONE
    analysis.score = 0
  end
  return analysis
end

local function analyse_choice_supply(state, task, expr, activation, intents)
  local metadata = IR.active_metadata(expr)
  if metadata.dynamic then
    return analyse_dynamic_choice_supply(state, task, expr, activation, intents)
  end
  local score, certainty = IR.supply_score(metadata, intents)
  return {
    task = task,
    expr = expr,
    activation = activation,
    size = #(expr.choices or {}),
    dynamic = false,
    score = score,
    certainty = certainty,
  }
end

local function append_static_choice_candidates(analysis, intents, candidates)
  for ai = 1, analysis.size do
    local alternative = analysis.expr.choices[ai]
    local metadata = IR.active_metadata(alternative)
    for ii = 1, #intents do
      local certainty = IR.supply_relation(metadata, intents[ii])
      if certainty == IR.SUPPLY_EXACT then
        candidates[#candidates + 1] = choice_candidate(analysis.task, analysis.expr, analysis.activation, ai)
        break
      end
    end
  end
end

local function task_advances_guard(state, task)
  if not task or task.status ~= 'active' then
    return false
  end
  local _, _, residual_state = inspect_transparent_residual(state, task, task.activation, task.expr)
  return residual_state ~= RESIDUAL_STATIC
end

local function exchange_domain_only(intents)
  if #intents == 0 then
    return false
  end
  for i = 1, #intents do
    if intents[i].kind ~= 'exchange' then
      return false
    end
  end
  return true
end

local function has_compatible_exchange_pair(state, intents)
  local compatible = compatibility_fn(state)
  for i = 1, #intents - 1 do
    for j = i + 1, #intents do
      if compatible(intents[i], intents[j]) then
        return true
      end
    end
  end
  return false
end

local function better_frontier_supplier(score, size, best_score, best_size)
  return score > best_score or (score == best_score and score > 0 and (best_size == nil or size < best_size))
end

local function reveal_supplier_guard(state, probe)
  evaluate_guard_residual(state, probe.task, probe.guard, probe.activation)
  local profile_plan = state.profile_plan
  if profile_plan then
    profile_plan.opaque_supplier_revelations = (profile_plan.opaque_supplier_revelations or 0) + 1
  end
end

local function select_frontier_action(state, head)
  local first_branch = nil
  local guard_progress = nil
  local deterministic_progress = nil
  local best_choice, best_choice_size = nil, nil
  local best_exact, best_exact_score, best_exact_size = nil, 0, nil
  local best_opaque, best_opaque_score, best_opaque_size = nil, 0, nil
  local choice_analyses = nil
  local exact_candidates = nil
  local has_revealed_guard = false
  local first_probe = nil
  local exchange_only = exchange_domain_only(state.intents)
  if exchange_only and has_compatible_exchange_pair(state, state.intents) then
    return 'blocked'
  end

  local saw_or_else = false
  for i = head, #state.active do
    local task = state.tasks[state.active[i]]
    if task and task.status == 'active' then
      local expr = task.expr
      local kind = expr and expr.kind
      if kind ~= 'choice' and kind ~= 'or_else' then
        if task_advances_guard(state, task) then
          guard_progress = guard_progress or i
        end
        if state.residual_propagation_required then
          deterministic_progress = deterministic_progress or i
        end
        if metadata_has_exchange(IR.active_metadata(expr)) then
          return 'advance', i
        end
      else
        first_branch = first_branch or i
        local size = kind == 'choice' and #(expr.choices or {}) or 2
        if kind == 'or_else' then
          saw_or_else = true
        elseif best_choice_size == nil or size < best_choice_size then
          best_choice, best_choice_size = i, size
        end

        if exchange_only then
          local analysis
          if kind == 'choice' then
            analysis = analyse_choice_supply(state, task, expr, task.activation, state.intents)
            analysis.index = i
            choice_analyses = choice_analyses or {}
            choice_analyses[#choice_analyses + 1] = analysis
            if analysis.dynamic then
              if #analysis.exact_candidates > 0 then
                exact_candidates = exact_candidates or {}
                for ci = 1, #analysis.exact_candidates do
                  exact_candidates[#exact_candidates + 1] = analysis.exact_candidates[ci]
                end
              end
              has_revealed_guard = has_revealed_guard or analysis.has_revealed_guard
              if analysis.certainty == IR.SUPPLY_OPAQUE and first_probe == nil then
                first_probe = analysis.probe
              end
            end
          else
            local metadata = IR.active_metadata(expr)
            local score, certainty = IR.supply_score(metadata, state.intents)
            analysis = {
              index = i,
              size = size,
              dynamic = metadata.dynamic == true,
              score = score,
              certainty = certainty,
            }
          end

          if analysis.certainty == IR.SUPPLY_OPAQUE then
            if better_frontier_supplier(analysis.score, size, best_opaque_score, best_opaque_size) then
              best_opaque, best_opaque_score, best_opaque_size = analysis, analysis.score, size
            end
          elseif analysis.certainty == IR.SUPPLY_EXACT then
            if better_frontier_supplier(analysis.score, size, best_exact_score, best_exact_size) then
              best_exact, best_exact_score, best_exact_size = analysis, analysis.score, size
            end
          end
        end
      end
    end
  end

  if guard_progress then
    return 'advance', guard_progress
  end
  if state.residual_propagation_required and deterministic_progress then
    return 'advance', deterministic_progress
  end

  if exchange_only then
    if has_supplier(state, state.intents, IR.SUPPLY_EXACT) then
      return 'blocked'
    end

    if best_exact and best_exact.dynamic and has_revealed_guard and exact_candidates then
      for i = 1, #(choice_analyses or {}) do
        local analysis = choice_analyses[i]
        if not analysis.dynamic and analysis.certainty == IR.SUPPLY_EXACT then
          append_static_choice_candidates(analysis, state.intents, exact_candidates)
        end
      end
      if #exact_candidates > 0 then
        return 'branch',
          {
            kind = 'supplier_choice',
            candidates = exact_candidates,
            next_index = 1,
            certificate = nil,
          }
      end
    elseif best_exact then
      return 'advance', best_exact.index
    end

    if best_opaque and first_probe then
      reveal_supplier_guard(state, first_probe)
      return 'progress'
    end
    local fallback = best_opaque or best_exact
    if fallback then
      return 'advance', fallback.index
    end
    if saw_or_else then
      return 'advance', first_branch
    end
    return 'blocked'
  end

  if state.residual_propagation_required then
    setv(state, state, 'residual_propagation_required', false)
  end

  if saw_or_else then
    return 'advance', first_branch
  end
  return 'advance', best_choice or first_branch or head
end

-- Drain deterministic task work until the evaluator reaches a blocked domain
-- or one of the two option-level branch forms.  Branch control is represented
-- explicitly; no Lua call frame is used to remember an alternative.
local function drain_active(state)
  local profile_plan = state.profile_plan
  while state.active_head <= #state.active do
    local head = state.active_head
    local task_id = state.active[head]
    local task = state.tasks[task_id]
    local head_kind = task and task.status == 'active' and task.expr and task.expr.kind or nil
    local selected = head
    if head_kind == 'choice' or head_kind == 'or_else' then
      local action, payload = select_frontier_action(state, head)
      if action == 'progress' then
        return 'progress'
      elseif action == 'branch' then
        return 'branch', payload
      elseif action == 'blocked' then
        return 'blocked'
      elseif action == 'advance' then
        selected = payload
      else
        error('unknown frontier action: ' .. tostring(action), 0)
      end
    end
    if selected ~= head then
      local selected_id = state.active[selected]
      setv(state, state.active, selected, task_id)
      setv(state, state.active, head, selected_id)
      task_id = selected_id
      task = state.tasks[task_id]
    end
    setv(state, state, 'active_head', head + 1)
    if task and task.status == 'active' then
      if profile_plan then
        profile_plan.task_steps = profile_plan.task_steps + 1
        profile_plan.deterministic_steps = profile_plan.deterministic_steps + 1
      end
      local expr, kind = task.expr, task.expr.kind
      if profile_plan then
        local key = 'op_' .. tostring(kind)
        profile_plan[key] = (profile_plan[key] or 0) + 1
      end
      if kind == 'always' then
        if not complete_task(state, task, new_outcome(state, expr.vals, nil, task)) then
          local terminal = terminal_certificate(state)
          report_task_absence(state, task, terminal, 'terminal_completion', false)
          return 'retry', terminal
        end
      elseif kind == 'guard' then
        local parent_activation = task.activation
        local residual = evaluate_guard_residual(state, task, expr, parent_activation)
        setv(state, task, 'expr', residual)
        setv(state, task, 'activation', Path.child(parent_activation, 'guard:result'))
        if
          task.exchange_support_provenance
          and residual.kind == 'choice'
          and #(residual.choices or {}) == 0
        then
          local failure = Certificate.mark_failure(Certificate.local_absence(), task.id)
          report_task_absence(state, task, failure, 'guard_continuation_rejection', false)
          eliminate_exchange_support(state, failure)
          return 'retry', failure
        end
        setv(state, state, 'residual_propagation_required', true)
        add_active(state, task.id)
      elseif kind == 'and_then' then
        local parent_activation = task.activation
        pushv(state, task.frames, {
          kind = 'bind',
          fn = expr.fn,
          phase = expr.callback_phase,
          activation = parent_activation,
          continuation_footprint = expr.continuation_footprint,
        })
        setv(state, task, 'expr', expr.p)
        setv(state, task, 'activation', Path.child(parent_activation, 'and_then:prefix'))
        add_active(state, task.id)
      elseif kind == 'annotated' then
        local parent_activation = task.activation
        if expr.post then
          pushv(state, task.frames, { kind = 'wrap', fn = expr.post })
        end
        if expr.symmetry_key ~= nil then
          pushv(state, task.frames, { kind = 'symmetry_restore', previous_symmetry = task.symmetry_key })
          setv(state, task, 'symmetry_key', expr.symmetry_key)
        end
        setv(state, task, 'expr', expr.p)
        setv(state, task, 'activation', Path.child(parent_activation, 'annotated:body'))
        add_active(state, task.id)
      elseif kind == 'consequence' then
        pushv(state, state.effects, expr.effect)
        if not complete_task(state, task, new_outcome(state, pack_(), nil, task)) then
          local terminal = terminal_certificate(state)
          report_task_absence(state, task, terminal, 'terminal_completion', false)
          return 'retry', terminal
        end
      elseif kind == 'primitive' then
        if not execute_program(state, task, expr) then
          local terminal = terminal_certificate(state)
          report_task_absence(state, task, terminal, 'primitive_failure', false)
          return 'retry', terminal
        end
      elseif kind == 'product' then
        start_product(state, task, expr)
      elseif kind == 'choice' then
        if profile_plan then
          state.runtime.instrumentation:event(
            profile_plan,
            'choice',
            { alternatives = #(expr.choices or {}) }
          )
        end
        local occurrence = (task.choice_serial or 0) + 1
        setv(state, task, 'choice_serial', occurrence)
        return 'branch',
          {
            kind = 'choice',
            task_id = task.id,
            expr = expr,
            activation = task.activation,
            order = ChoiceOrder.indices(
              state.runtime,
              task,
              occurrence,
              #(expr.choices or {}),
              state.choice_generation
            ),
            next_index = 1,
            certificate = nil,
          }
      elseif kind == 'or_else' then
        local preferred = preferred_state_for(state, task, task.activation)
        if preferred.phase ~= 'preferred' then
          activate_or_else_fallback(
            state,
            task,
            expr,
            task.activation,
            preferred.evidence,
            preferred,
            preferred.parent
          )
        else
          return 'or_else',
            {
              kind = 'or_else_continuation',
              task_id = task.id,
              expr = expr,
              activation = task.activation,
              preferred = preferred,
              parent_preferred = preferred.parent,
            }
        end
      else
        error('unsupported Op kind: ' .. tostring(kind), 0)
      end
    end
  end
  return 'blocked'
end

local function analyse_domain(state)
  local profile_plan = state.profile_plan
  local domain =
    Domain.open(state.demand_index, state, compatibility_fn(state), state.runtime.branch_policy ~= 'legacy')
  local exchange = domain.exchange
  if profile_plan then
    profile_plan.intent_pairs_scanned = profile_plan.intent_pairs_scanned + exchange.scans
    profile_plan.compatible_pairs = profile_plan.compatible_pairs + exchange.compatible
    profile_plan.exchange_domains = profile_plan.exchange_domains + (exchange.selected and 1 or 0)
    profile_plan.zero_exchange_domains = profile_plan.zero_exchange_domains + exchange.zero_domains
    profile_plan.max_exchange_domain =
      math.max(profile_plan.max_exchange_domain or 0, exchange.selected_degree or 0)
    profile_plan.symmetry_exchange_pruned = profile_plan.symmetry_exchange_pruned
      + (exchange.symmetry_pruned or 0)
    Domain.each_group(domain, function(group)
      profile_plan.claim_groups_scanned = profile_plan.claim_groups_scanned + 1
      local size = #group.ids
      if size > profile_plan.max_claim_group then
        profile_plan.max_claim_group = size
      end
      if state.runtime.instrumentation.trace then
        local names, kinds, supply_sets, accepts, modes = {}, {}, {}, {}, {}
        for j = 1, #group.intents do
          local intent = group.intents[j]
          local rule = IR.rule(intent.program)
          names[j] = rule.name or intent.kind
          kinds[j] = rule.type
          supply_sets[j] = Supply.describe(rule.supplies)
          accepts[j] = tostring(rule.accepts_supply)
          modes[j] = rule.mode or rule.type
        end
        state.runtime.instrumentation:event(profile_plan, 'claim_group', {
          key = tostring(group.key and (group.key.name or group.key._fibers_id or group.key) or '<nil>'),
          size = size,
          serial_only = group.serial_only,
          group_accepts_supply = group.accepts_supply,
          names = table.concat(names, '|'),
          kinds = table.concat(kinds, '|'),
          supply_sets = table.concat(supply_sets, '|'),
          accepts_supply = table.concat(accepts, '|'),
          modes = table.concat(modes, '|'),
        })
      end
    end)
  end
  return domain
end

-- Apply only the two reductions already certified by the previous machine.
-- The return value is true for progress, false plus a certificate for a failed
-- forced action, and nil when genuine branching remains.
local function raw_exchange_program(op)
  op = inspect_transparent_residual(nil, nil, nil, op)
  if not op or op.kind ~= 'primitive' then
    return nil
  end
  local program = op.program
  if not program or programme_kind(program) ~= 'exchange' then
    return nil
  end
  return program
end

local function raw_choice_exchange_demand(state, frame, choice_index)
  local task = state.tasks[frame.task_id]
  local alternative = frame.expr.choices[choice_index]
  local alternative_activation = Path.child(frame.activation, 'choice:' .. tostring(choice_index))
  local residual, activation = inspect_transparent_residual(state, task, alternative_activation, alternative)
  local program = raw_exchange_program(residual)
  if not program then
    return nil
  end
  return {
    id = 'choice:' .. tostring(frame.task_id) .. ':' .. tostring(choice_index),
    kind = 'exchange',
    task_id = frame.task_id,
    root_id = task and task.root_id or nil,
    program = program,
    activation = activation,
    resource = program.resource,
    role = program.role,
    scope_path = task and task.scope_path or nil,
    interest = type(program.interest) == 'function' and program.interest(state.runtime, program)
      or program.interest,
    absence_check = program.absence_check,
  }
end

local function recruited_root_may_supply(state, demand)
  for _, root in pairs(state.roots) do
    if root and not root.done then
      local request = root.request
      local metadata = request and (request.metadata or IR.metadata(request.op)) or nil
      if request then
        request.metadata = metadata
      end
      if metadata and IR.metadata_may_supply(metadata, demand) then
        return true
      end
    end
  end
  return false
end

local function has_exchange_support(state, demand, domain)
  if domain then
    if Domain.has_exchange_partner(domain, demand) then
      return true
    end
  else
    local compatible = compatibility_fn(state)
    for i = 1, #state.intents do
      if compatible(demand, state.intents[i]) then
        return true
      end
    end
  end
  if recruited_root_may_supply(state, demand) then
    return true
  end
  if has_supplier(state, { demand }) then
    return true
  end
  return nil
end

local function raw_choice_exchange_viable(state, frame, choice_index)
  local demand = raw_choice_exchange_demand(state, frame, choice_index)
  if not demand then
    return true
  end

  if has_exchange_support(state, demand) then
    return true
  end

  local certificate = Certificate.from_intents({ demand })
  frame.certificate = Certificate.merge(frame.certificate, certificate)
  report_task_absence(state, state.tasks[frame.task_id], certificate, 'no_supplier', false)
  local profile_plan = state.profile_plan
  if profile_plan then
    profile_plan.choice_alternatives_pruned = profile_plan.choice_alternatives_pruned + 1
  end
  return false
end

local function recruit_forced_raw_exchange(state, exchange)
  if #state.intents ~= 1 or exchange.compatible ~= 0 or state.session.stack ~= nil then
    return false
  end
  local intent = state.intents[1]
  local task = intent and state.tasks[intent.task_id]
  local current = task and #task.frames == 0 and raw_exchange_program(task.expr) or nil
  if not current or current ~= intent.program then
    return false
  end
  local row, count = supplier_candidate(state)
  if count ~= 1 then
    return false
  end
  local request = state.requests[row.id] or state.runtime.pending_by_id[row.id]
  local supplier = raw_exchange_program(request and request.op)
  if not supplier or supplier.resource ~= current.resource or supplier.role == current.role then
    return false
  end
  add_root(state, row.id)
  local profile_plan = state.profile_plan
  if profile_plan then
    profile_plan.normalisation_rounds = profile_plan.normalisation_rounds + 1
  end
  return true
end

local function current_or_else_continuation(state)
  local stack = state.session and state.session.stack
  local frame = stack and stack[#stack - 1] or nil
  if frame and frame.kind == 'or_else_continuation' and frame.waiting then
    return frame
  end
  return nil
end

-- Close the current preferred occurrence when its exact exchange demand has no
-- admissible support in the fully reduced interacting product.  This is the
-- smallest product-support proof: every active sibling intent is visible,
-- pending suppliers are checked through the dependency index, and unresolved
-- dynamic code would have prevented the node from reaching the domain fixed
-- point.  More general Hall deficits remain ordinary search until a particular
-- preferred occurrence can be justified under explicit sibling assumptions.
local function close_unsupported_product_preferred(state, domain)
  local frame = current_or_else_continuation(state)
  if not frame or frame.preferred.phase ~= 'preferred' then
    return nil
  end
  for i = state.active_head, #state.active do
    local pending_task = state.tasks[state.active[i]]
    if pending_task and pending_task.status == 'active' then
      return nil
    end
  end

  local demand
  for i = 1, #state.intents do
    local intent = state.intents[i]
    local task = state.tasks[intent.task_id]
    if
      intent.kind == 'exchange'
      and task
      and task.preferred_state == frame.preferred
      and task.id == frame.task_id
    then
      if demand then
        return nil
      end
      demand = intent
    end
  end
  if not demand then
    return nil
  end

  if has_exchange_support(state, demand, domain) then
    return nil
  end

  local task = state.tasks[frame.task_id]
  if
    not task
    or #task.frames ~= (frame.task_frame_depth or #task.frames)
    or not task.expr
    or task.expr.kind ~= 'primitive'
  then
    return nil
  end

  local certificate = Certificate.from_intents({ demand })

  -- This exact direct preferred has no speculative ledger contribution. Remove
  -- only its blocked intent and continuation boundary, preserving fallback
  -- transitions already established by sibling lanes in the same product.
  remove_intent_ids(state, { demand.id })
  setv(state, task, 'status', 'active')
  close_preferred_occurrence(state, frame, certificate, 'product_support_absent')

  local stack = state.session.stack
  if not stack or stack[#stack - 1] ~= frame or not stack[#stack] or stack[#stack].kind ~= 'node' then
    error('product support closure lost its or_else continuation', 0)
  end
  stack[#stack] = nil
  stack[#stack] = nil
  state.search_depth = math.max(1, state.search_depth - 1)
  local parent = stack[#stack]
  if parent and parent.kind == 'node' then
    parent.phase = 'reduce'
  else
    state.session.stack = nil
    state.session.phase = 'reduce'
  end

  local profile_plan = state.profile_plan
  if profile_plan then
    profile_plan.product_support_closures = (profile_plan.product_support_closures or 0) + 1
  end
  return true
end

local function apply_forced_domain(state, domain)
  if state.runtime.normalise_search == false then
    return nil
  end
  local closed, closed_certificate = close_unsupported_product_preferred(state, domain)
  if closed ~= nil then
    return closed, closed_certificate
  end
  local profile_plan = state.profile_plan
  local exchange = domain.exchange
  if recruit_forced_raw_exchange(state, exchange) then
    return true
  end
  if exchange.selected_degree == 1 and exchange.selected then
    if not has_supplier(state, { exchange.selected }) then
      if profile_plan then
        profile_plan.forced_exchange_opportunities = profile_plan.forced_exchange_opportunities + 1
        profile_plan.forced_exchanges = profile_plan.forced_exchanges + 1
        profile_plan.normalisation_rounds = profile_plan.normalisation_rounds + 1
      end
      local pair = Domain.selected_unique_exchange(domain)
      if pair and match_intents(state, pair.left, pair.right) then
        return true
      end
      local terminal = terminal_certificate(state)
      report_intent_absence(state, state.intents, terminal, 'forced_exchange_failure')
      return false, terminal
    end
  end

  local forced_group
  Domain.each_group(domain, function(group)
    if
      not forced_group
      and group.serial_only
      and not group.accepts_supply
      and not has_supplier(state, group.intents)
    then
      forced_group = group
    end
  end)
  if forced_group then
    if profile_plan then
      profile_plan.forced_claim_opportunities = profile_plan.forced_claim_opportunities + 1
      profile_plan.forced_claims = profile_plan.forced_claims + 1
      profile_plan.normalisation_rounds = profile_plan.normalisation_rounds + 1
    end
    if resolve_transition_set(state, forced_group, forced_group.ids) then
      return true
    end
    local terminal = terminal_certificate(state)
    report_intent_absence(state, forced_group.intents, terminal, 'forced_transition_failure')
    return false, terminal
  end
  return nil
end

local function new_domain_frame(domain)
  return { kind = 'domain', domain = domain, cursor = Domain.cursor(domain), certificate = nil }
end

local function observe_supplier(state, frame)
  if frame.supplier_ready then
    return
  end
  frame.supplier_ready = true
  local row, count = nil, 0
  if frame.domain.accepts_participant_supply then
    row, count = supplier_candidate(state)
  end
  local profile_plan = state.profile_plan
  if profile_plan then
    profile_plan.footprint_checks = profile_plan.footprint_checks
      + math.max(0, map_count(state.requests) - map_count(state.roots))
    profile_plan.recruitment_candidates = profile_plan.recruitment_candidates + count
    if row then
      profile_plan.recruitment_best_score = math.max(profile_plan.recruitment_best_score or 0, row.score or 0)
      profile_plan.footprint_matches = profile_plan.footprint_matches + count
      local key = 'footprint_' .. tostring(row.reason or 'unknown') .. '_matches'
      profile_plan[key] = (profile_plan[key] or 0) + 1
    end
  end
  frame.supplier_row = row
end

local function next_frontier_alternative(state, frame)
  return Domain.next(frame.cursor, {
    witness_cursor = function(intent)
      return witness_cursor(state, intent)
    end,
    supplier = function()
      observe_supplier(state, frame)
      return frame.supplier_row
    end,
  })
end

local function prioritise_choice_supplier(state, frame)
  if not exchange_domain_only(state.intents) then
    return
  end
  local first = frame.next_index
  local best, best_score = first, -1
  for position = first, #frame.order do
    local index = frame.order[position]
    local task = state.tasks[frame.task_id]
    local alternative = frame.expr.choices[index]
    local alternative_activation = Path.child(frame.activation, 'choice:' .. tostring(index))
    local residual = inspect_transparent_residual(state, task, alternative_activation, alternative)
    local score = IR.supply_score(IR.active_metadata(residual), state.intents)
    if score > best_score then
      best, best_score = position, score
    end
  end
  if best ~= first then
    frame.order[first], frame.order[best] = frame.order[best], frame.order[first]
  end
end

local function next_branch_alternative(state, frame)
  if frame.kind == 'choice' then
    while true do
      prioritise_choice_supplier(state, frame)
      local index = frame.order[frame.next_index]
      if not index then
        return nil
      end
      frame.next_index = frame.next_index + 1
      -- Do not perform unbounded pruning after the caller's work quantum has
      -- been consumed. Entering the alternative creates a resumable child node
      -- which will suspend before further reduction.
      if
        (state.session.work_remaining ~= nil and state.session.work_remaining <= 0)
        or raw_choice_exchange_viable(state, frame, index)
      then
        return {
          kind = 'choice',
          task_id = frame.task_id,
          expr = frame.expr,
          choice_index = index,
          activation = frame.activation,
          supplier_domain = false,
        }
      end
    end
  elseif frame.kind == 'supplier_choice' then
    local candidate = frame.candidates[frame.next_index]
    if not candidate then
      return nil
    end
    frame.next_index = frame.next_index + 1
    return {
      kind = 'choice',
      task_id = candidate.task_id,
      expr = candidate.expr,
      choice_index = candidate.choice_index,
      activation = candidate.activation,
      supplier_domain = true,
    }
  elseif frame.kind == 'domain' then
    return next_frontier_alternative(state, frame)
  end
  error('unknown search branch frame: ' .. tostring(frame.kind), 0)
end

activate_or_else_fallback = function(state, task, expr, activation, certificate, preferred, parent_preferred)
  local profile_plan = state.profile_plan
  if profile_plan then
    profile_plan.fallback_transitions = profile_plan.fallback_transitions + 1
    state.runtime.instrumentation:event(profile_plan, 'or_else_fallback')
  end
  local gate = state.absence_gate
  if not gate then
    gate = Certificate.new_absence_gate()
    setv(state, state, 'absence_gate', gate)
  end
  if preferred and preferred.phase ~= 'fallback' then
    preferred.phase = 'fallback'
    if profile_plan then
      profile_plan.fallback_dependency_transitions = (profile_plan.fallback_dependency_transitions or 0) + 1
    end
  end
  enable_full_dependency_frontier(state)
  Certificate.each(certificate, 'check', function(check)
    pushv(state, gate.checks, check)
  end)
  setv(state, task, 'preferred_state', parent_preferred)
  setv(state, task, 'expr', expr.q)
  setv(
    state,
    task,
    'activation',
    Path.child(activation, 'or_else:fallback:' .. Certificate.gate_epoch(certificate))
  )
  add_active_next(state, task.id)
end

local function prepare_alternative(state, frame, alt)
  local profile_plan = state.profile_plan
  if alt.kind == 'choice' then
    if profile_plan then
      profile_plan.choice_branches = profile_plan.choice_branches + 1
      if alt.supplier_domain then
        profile_plan.supplier_domain_branches = (profile_plan.supplier_domain_branches or 0) + 1
      end
    end
    local task = state.tasks[alt.task_id]
    setv(state, task, 'expr', alt.expr.choices[alt.choice_index])
    setv(state, task, 'activation', Path.child(alt.activation, 'choice:' .. tostring(alt.choice_index)))
    add_active(state, task.id)
    return true
  elseif alt.kind == 'exchange' then
    if profile_plan then
      state.runtime.instrumentation:event(profile_plan, 'exchange_pair', {
        left = alt.pair.left,
        right = alt.pair.right,
        domain = alt.domain,
      })
    end
    return match_intents(state, alt.pair.left, alt.pair.right)
  elseif alt.kind == 'witness' then
    if profile_plan then
      profile_plan.witness_alternatives = profile_plan.witness_alternatives + 1
    end
    return resolve_witness(state, alt.intent_id, alt.alternative, alt.alternative_index)
  elseif alt.kind == 'transition' then
    if profile_plan then
      profile_plan.claim_branches = profile_plan.claim_branches + 1
      if state.runtime.instrumentation.trace then
        local names = {}
        for i = 1, #alt.ids do
          local intent = state.intent_by_id[alt.ids[i]]
          local rule = intent and intent.program and IR.rule(intent.program)
          names[i] = (rule and rule.name)
            or (intent and intent.program and intent.program.name)
            or (intent and intent.kind)
            or '<missing>'
        end
        state.runtime.instrumentation:event(profile_plan, 'claim_branch', {
          transition_kind = alt.transition_kind,
          size = #alt.ids,
          names = table.concat(names, '|'),
          group_key = tostring(
            alt.group.key and (alt.group.key.name or alt.group.key._fibers_id or alt.group.key) or '<nil>'
          ),
        })
      end
      if alt.transition_kind == 'all' then
        profile_plan.claim_all_branches = profile_plan.claim_all_branches + 1
      elseif alt.transition_kind == 'closure' then
        profile_plan.claim_closure_branches = profile_plan.claim_closure_branches + 1
      else
        profile_plan.claim_single_branches = profile_plan.claim_single_branches + 1
      end
    end
    local resolved = resolve_transition_set(state, alt.group, alt.ids)
    if profile_plan and alt.transition_kind == 'closure' then
      if resolved then
        profile_plan.claim_closure_successes = profile_plan.claim_closure_successes + 1
      else
        profile_plan.claim_closure_failures = profile_plan.claim_closure_failures + 1
      end
    end
    return resolved
  elseif alt.kind == 'recruit' then
    local row = alt.row
    if profile_plan then
      profile_plan.recruit_branches = profile_plan.recruit_branches + 1
      state.runtime.instrumentation:event(profile_plan, 'recruit_root', { root = row.id, score = row.score })
    end
    add_root(state, row.id)
    return true
  elseif alt.kind == 'exclude' then
    local row = alt.row
    if profile_plan then
      profile_plan.exclude_branches = profile_plan.exclude_branches + 1
      state.runtime.instrumentation:event(profile_plan, 'exclude_root', { root = row.id })
    end
    local ids = row.equivalent_ids or { row.id }
    for i = 1, #ids do
      setv(state, state.excluded_roots, ids[i], true)
    end
    return true
  end
  error('unknown search alternative: ' .. tostring(alt.kind), 0)
end

local function selected_choice(frame)
  if frame.kind == 'choice' then
    return frame.expr, frame.order[frame.next_index - 1]
  end
  local candidate = frame.candidates[frame.next_index - 1]
  return candidate.expr, candidate.choice_index
end

local function branch_child_result(state, frame, outcome, candidate, certificate)
  if frame.kind == 'choice' or frame.kind == 'supplier_choice' then
    if outcome == 'hit' then
      local expr, chosen = selected_choice(frame)
      local defeats = {}
      for i = 1, #(expr.choices or {}) do
        if i ~= chosen then
          collect_defeat_effects(expr.choices[i], defeats)
        end
      end
      candidate = attach_candidate_effects(state.runtime, candidate, defeats)
      if candidate then
        return 'done', 'hit', candidate, nil
      end
      return 'continue'
    end
    report_task_absence(state, state.tasks[frame.task_id], certificate, 'choice_alternative', false)
    eliminate_exchange_support(state, certificate)
    frame.certificate = Certificate.merge(frame.certificate, certificate)
    return 'continue'
  elseif frame.kind == 'or_else_continuation' then
    if outcome == 'hit' then
      setv(state, state.tasks[frame.task_id], 'preferred_state', frame.parent_preferred)
      return 'done', 'hit', candidate, nil
    end
    close_preferred_occurrence(state, frame, certificate, 'primary_closure')
    return 'resume'
  elseif frame.kind == 'domain' then
    if outcome == 'hit' then
      return 'done', 'hit', candidate, nil
    end
    report_intent_absence(state, state.intents, certificate, 'domain_alternative')
    frame.certificate = Certificate.merge(frame.certificate, certificate)
    return 'continue'
  end
  error('unknown branch result frame: ' .. tostring(frame.kind), 0)
end

local function exhausted_branch_result(state, frame)
  if frame.kind == 'choice' or frame.kind == 'supplier_choice' then
    if frame.kind == 'choice' and #(frame.expr.choices or {}) == 0 then
      local certificate = Certificate.mark_failure(Certificate.local_absence(), frame.task_id)
      report_task_absence(state, state.tasks[frame.task_id], certificate, 'empty_choice', false)
      return certificate
    end
    return frame.certificate or terminal_certificate(state)
  elseif frame.kind == 'domain' then
    local certificate = Certificate.merge(frame.certificate, terminal_certificate(state))
    report_intent_absence(state, state.intents, certificate, 'domain_exhaustion')
    return certificate
  end
  error('unknown exhausted branch frame: ' .. tostring(frame.kind), 0)
end

local function finish_node(session, outcome, candidate, certificate)
  local state, stack = session.state, session.stack
  while true do
    if not stack then
      session.result_kind = outcome
      session.result_candidate = candidate
      session.result_certificate = certificate
      return true
    end

    local node = stack[#stack]
    if not node or node.kind ~= 'node' then
      error('search stack lost its node frame', 0)
    end
    stack[#stack] = nil

    local branch = stack[#stack]
    if not branch then
      session.stack = nil
      session.result_kind = outcome
      session.result_candidate = candidate
      session.result_certificate = certificate
      return true
    end
    if branch.kind == 'node' or not branch.waiting then
      error('search stack lost its branch continuation', 0)
    end

    local mark = branch.mark
    -- A successful production hit remains in the session-owned speculative
    -- state all the way through validation and commit.  Failed alternatives
    -- still roll back immediately.  The only successful child which may need
    -- to continue searching is a choice whose defeat effects are refused; in
    -- that case roll back after the refusal is known.
    if outcome ~= 'hit' then
      state.trail:rollback(mark)
    end

    local action, next_outcome, next_candidate, next_certificate =
      branch_child_result(state, branch, outcome, candidate, certificate)
    if action == 'continue' then
      if outcome == 'hit' then
        state.trail:rollback(mark)
      end
      branch.mark, branch.waiting = nil, false
      state.search_depth = math.max(1, state.search_depth - 1)
      return false
    elseif action == 'resume' then
      branch.mark, branch.waiting = nil, false
      state.search_depth = math.max(1, state.search_depth - 1)
      stack[#stack] = nil
      local parent = stack[#stack]
      if not parent or parent.kind ~= 'node' then
        error('or_else fallback lost its parent node', 0)
      end
      parent.phase = 'reduce'
      return false
    end

    branch.mark, branch.waiting = nil, false
    state.search_depth = math.max(1, state.search_depth - 1)
    stack[#stack] = nil
    outcome, candidate, certificate = next_outcome, next_candidate, next_certificate
  end
end

local function start_branch_alternative(session, frame)
  local state = session.state
  while true do
    local alt = next_branch_alternative(state, frame)
    if not alt then
      session.stack[#session.stack] = nil
      local certificate = exhausted_branch_result(state, frame)
      local stack = session.stack
      local parent_branch = stack and stack[#stack - 1] or nil
      if not (parent_branch and parent_branch.kind == 'or_else_continuation') then
        eliminate_exchange_support(state, certificate)
      end
      return finish_node(session, 'retry', nil, certificate)
    end

    local profile_plan = state.profile_plan
    if profile_plan then
      profile_plan.branches = profile_plan.branches + 1
    end
    local mark = state.trail:mark()
    local ready = prepare_alternative(state, frame, alt) ~= false
    if ready then
      frame.mark, frame.waiting, frame.current_alternative = mark, true, alt
      state.search_depth = state.search_depth + 1
      if profile_plan and state.search_depth > profile_plan.max_depth then
        profile_plan.max_depth = state.search_depth
      end
      session.stack[#session.stack + 1] = { kind = 'node', phase = 'enter' }
      return false
    end
    state.trail:rollback(mark)
  end
end

local function push_branch(session, branch)
  if not session.stack then
    local stack = session.stack_arena or {}
    session.stack_arena = stack
    stack[1] = { kind = 'node', phase = 'waiting' }
    stack[2] = branch
    session.stack = stack
    session.phase = nil
  else
    local node = session.stack[#session.stack]
    node.phase = 'waiting'
    session.stack[#session.stack + 1] = branch
  end
end

local function push_or_else_continuation(session, frame)
  local state = session.state
  local stack = session.stack
  if not stack then
    stack = session.stack_arena or {}
    session.stack_arena = stack
    stack[1] = { kind = 'node', phase = 'waiting' }
    session.stack = stack
    session.phase = nil
  else
    stack[#stack].phase = 'waiting'
  end

  frame.mark = state.trail:mark()
  frame.waiting = true
  stack[#stack + 1] = frame
  state.search_depth = state.search_depth + 1

  local profile_plan = state.profile_plan
  if profile_plan then
    profile_plan.preferred_entries = profile_plan.preferred_entries + 1
    state.runtime.instrumentation:event(profile_plan, 'or_else_preferred')
    if state.search_depth > profile_plan.max_depth then
      profile_plan.max_depth = state.search_depth
    end
  end

  local task = state.tasks[frame.task_id]
  frame.task_frame_depth = #task.frames
  setv(state, task, 'preferred_state', frame.preferred)
  setv(state, task, 'expr', frame.expr.p)
  setv(state, task, 'activation', Path.child(frame.activation, 'or_else:preferred'))
  add_active_next(state, task.id)
  stack[#stack + 1] = { kind = 'node', phase = 'enter' }
end

local function advance_search(session)
  local state = session.state
  while true do
    if session.result_kind then
      return session.result_candidate, session.result_certificate, false
    end

    local stack = session.stack
    local frame = stack and stack[#stack] or session
    local is_node = not stack or frame.kind == 'node'

    if not is_node then
      if frame.waiting then
        error('waiting branch has no child node', 0)
      end
      if start_branch_alternative(session, frame) and session.result_kind then
        return session.result_candidate, session.result_certificate, false
      end
    elseif frame.phase == 'enter' then
      frame.phase = 'reduce'
    elseif frame.phase == 'reduce' then
      if not begin_search_round(state) then
        return nil, Certificate.new(), true
      end

      local action, payload = drain_active(state)
      if action == 'retry' then
        if finish_node(session, 'retry', nil, payload) and session.result_kind then
          return session.result_candidate, session.result_certificate, false
        end
      elseif action == 'branch' then
        push_branch(session, payload)
      elseif action == 'or_else' then
        push_or_else_continuation(session, payload)
      elseif action == 'progress' then
        -- A demand-driven guard probe learned a residual without changing the
        -- speculative ledger. Re-enter reduction so the refined metadata can
        -- guide supplier selection within the normal work quantum.
      else
        local candidate = final_candidate(state)
        if candidate then
          if finish_node(session, 'hit', candidate, nil) and session.result_kind then
            return session.result_candidate, session.result_certificate, false
          end
        else
          local domain = analyse_domain(state)
          local progressed, forced_certificate = apply_forced_domain(state, domain)
          if progressed == true then
            -- Continue the fixed point in the inline or stacked node.
          elseif progressed == false then
            if finish_node(session, 'retry', nil, forced_certificate) and session.result_kind then
              return session.result_candidate, session.result_certificate, false
            end
          else
            push_branch(session, new_domain_frame(domain))
          end
        end
      end
    elseif frame.phase == 'waiting' then
      error('node is waiting without an active branch frame', 0)
    else
      error('unknown search node phase: ' .. tostring(frame.phase), 0)
    end
  end
end

M.advance = advance_search

function M.new_session(runtime, requests, focus_id, component)
  local session = SearchSession.new(runtime, requests, focus_id, component)
  if not session then
    return nil
  end
  session.machine = M
  local state = session.state
  state.demand_index = nil
  Ledger.begin_state(state)
  if not state.trail then
    state.trail = Trail.new(runtime.stats, session.profile_plan)
  else
    state.trail:begin(runtime.stats, session.profile_plan)
  end
  state.trail.on_rollback = Ledger.invalidate
  state.trail.rollback_context = state
  add_root(state, focus_id)
  return session
end

function M.search(runtime, requests, focus_id, search_limit, component)
  local session = M.new_session(runtime, requests, focus_id, component)
  if not session then
    return nil
  end
  local candidate, certificate, unknown = session:advance(search_limit or runtime.search_limit)
  return candidate, certificate, unknown, session
end

M._Trail = Trail
M.path = Path

return M

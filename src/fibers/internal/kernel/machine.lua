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
  return Path.label(intent.activation) .. '@' .. object_version_label(program.location or program.group)
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

local complete_task

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
      local request = state.roots[task.root_id].request
      if frame.phase == 'map' then
        -- A map callback has already produced the next completed value.  Keep
        -- unwinding this task directly instead of allocating Op.always and
        -- scheduling another deterministic evaluator step.
        outcome = new_outcome(
          state,
          packv(
            state,
            state.runtime:_call_in_phase('map', 'callback_error', frame.fn, unpack_pack(outcome.pack))
          ),
          nil,
          task
        )
      else
        if frame.phase == 'guard' then
          local cached = request.memo[frame.activation]
          if not cached then
            cached = state.runtime:_call_in_phase('guard', 'callback_error', frame.fn, {
              runtime = state.runtime,
              now = function()
                return state.runtime:now()
              end,
            })
            if not Op.is_op(cached) then
              error('guard callback must return an Op', 0)
            end
            verify_continuation_dependencies(state, task, frame, cached)
            request.memo[frame.activation] = cached
          end
          setv(state, task, 'expr', cached)
          setv(state, task, 'activation', Path.child(frame.activation, 'guard:result'))
        else
          local next_op =
            state.runtime:_call_in_phase('and_then', 'callback_error', frame.fn, unpack_pack(outcome.pack))
          if not Op.is_op(next_op) then
            error('and_then callback must return an Op', 0)
          end
          verify_continuation_dependencies(state, task, frame, next_op)
          setv(state, task, 'expr', next_op)
          setv(
            state,
            task,
            'activation',
            Path.child(frame.activation, 'and_then:result:' .. Path.label(outcome.activation))
          )
        end
        add_active(state, task.id)
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

local function add_root(state, root_id)
  if state.roots[root_id] then
    return
  end
  local request = state.requests[root_id]
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
  task.choice_serial, task.symmetry_key = 0, nil
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

local function intents_compatible(a, b)
  if a.kind ~= 'exchange' or b.kind ~= 'exchange' then
    return false
  end
  if a.resource ~= b.resource then
    return false
  end
  if a.role == b.role then
    return false
  end
  if a.root_id ~= b.root_id then
    return true
  end
  return same_root_compatible(a, b)
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

local function block_intent(state, task, program, occurrence)
  state.next_intent = state.next_intent + 1
  setv(state, task, 'status', 'blocked')
  local intent = state.session:acquire_record('intent')
  intent.id, intent.kind = state.next_intent, programme_kind(program)
  intent.task_id, intent.root_id, intent.program = task.id, task.root_id, program
  intent.payload = occurrence and occurrence.payload or nil
  intent.activation = task.activation
  intent.resource, intent.role = program.resource or program.group, program.role
  intent.value = program.payload_field == 'value' and occurrence.payload or program.value
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
      resource = tostring(program.resource or program.group),
    })
  end
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
  local labels = { Path.label(a.activation), Path.label(b.activation) }
  table.sort(labels)
  local fact = 'exchange:' .. table.concat(labels, '+')
  setv(state, put_task, 'activation', Path.child(put_task.activation, fact))
  setv(state, get_task, 'activation', Path.child(get_task.activation, fact))
  if not complete_task(state, put_task, new_outcome(state, PACK_TRUE, nil, put_task)) then
    return false
  end
  if not complete_task(state, get_task, new_outcome(state, packv(state, put.value), nil, get_task)) then
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
      local value =
        Ledger.project(state, task, program.location, program.orientation or program.demand_tag, state.trail)
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
    state.used_fallback == true,
    state.runtime.epoch,
    state.runtime.pending_generation,
    #state.negative_checks > 0 and state.negative_checks or nil,
    #state.fallback_interests > 0 and state.fallback_interests or nil,
    state.search_steps
  )

  -- Effect merge and preparation are part of world admissibility. A structured
  -- refusal therefore rejects this derivation and lets ordinary search
  -- backtrack to another choice, partner or fallback world.
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

local function execute_program(state, task, program, occurrence)
  if not program or program._fibers_program ~= true then
    error('primitive payload is not a kernel programme', 0)
  end

  local kind = programme_kind(program)
  if kind == 'exchange' then
    block_intent(state, task, program, occurrence)
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
    local version = program.payload_version and occurrence.payload or program.version
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
    block_intent(state, task, program, occurrence)
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
    local patch = program.patch
    if program.payload_patch == 'replace' then
      patch = { kind = 'replace', value = occurrence.payload }
    elseif program.payload_patch == 'presence_put' then
      patch = { kind = 'presence', ops = { { op = 'put', value = occurrence.payload } } }
    end
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
    block_intent(state, task, program, occurrence)
    return true
  end

  error('unknown programme kind: ' .. tostring(kind), 0)
end

local function has_supplier(state, intents)
  return state.runtime:_has_supplier(intents, state.roots, state.excluded_roots, state.requests)
end

local function supplier_candidate(state)
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

local function begin_search_round(state)
  local session = state.session
  if session and session.work_remaining ~= nil then
    if session.work_remaining <= 0 then
      return false
    end
    session.work_remaining = session.work_remaining - 1
  elseif state.search_steps >= state.search_limit then
    return false
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

-- Drain deterministic task work until the evaluator reaches a blocked domain
-- or one of the two option-level branch forms.  Branch control is represented
-- explicitly; no Lua call frame is used to remember an alternative.
local function drain_active(state)
  local profile_plan = state.profile_plan
  while state.active_head <= #state.active do
    local task_id = state.active[state.active_head]
    setv(state, state, 'active_head', state.active_head + 1)
    local task = state.tasks[task_id]
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
          return 'retry', terminal_certificate(state)
        end
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
          return 'retry', terminal_certificate(state)
        end
      elseif kind == 'primitive' then
        if not execute_program(state, task, expr.descriptor, expr) then
          return 'retry', terminal_certificate(state)
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
        return 'branch',
          {
            kind = 'or_else',
            task_id = task.id,
            expr = expr,
            activation = task.activation,
            phase = 'preferred',
            certificate = nil,
            preferred_certificate = nil,
          }
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
    Domain.open(state.demand_index, state, intents_compatible, state.runtime.branch_policy ~= 'legacy')
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
  if not op or op.kind ~= 'primitive' then
    return nil
  end
  local program = op.descriptor
  if not program or programme_kind(program) ~= 'exchange' then
    return nil
  end
  return program
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
  local request = state.requests[row.id]
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

local function apply_forced_domain(state, domain)
  if state.runtime.normalise_search == false then
    return nil
  end
  local profile_plan = state.profile_plan
  local exchange = domain.exchange
  if recruit_forced_raw_exchange(state, exchange) then
    return true
  end
  if #state.intents == 2 and exchange.selected_degree == 1 and exchange.compatible == 1 then
    if not has_supplier(state, { exchange.selected }) then
      if profile_plan then
        profile_plan.forced_exchange_opportunities = profile_plan.forced_exchange_opportunities + 1
        profile_plan.forced_exchanges = profile_plan.forced_exchanges + 1
        profile_plan.normalisation_rounds = profile_plan.normalisation_rounds + 1
      end
      local pair = Domain.unique_exchange(domain)
      if pair and match_intents(state, pair.left, pair.right) then
        return true
      end
      local terminal = terminal_certificate(state)
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
    return false, terminal_certificate(state)
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

local function next_branch_alternative(state, frame)
  if frame.kind == 'choice' then
    local index = frame.order[frame.next_index]
    if not index then
      return nil
    end
    frame.next_index = frame.next_index + 1
    return { kind = 'choice', choice_index = index }
  elseif frame.kind == 'or_else' then
    if frame.phase == 'preferred' then
      frame.phase = 'preferred_running'
      return { kind = 'or_else_preferred' }
    elseif frame.phase == 'fallback' then
      frame.phase = 'fallback_running'
      return { kind = 'or_else_fallback' }
    end
    return nil
  elseif frame.kind == 'domain' then
    return next_frontier_alternative(state, frame)
  end
  error('unknown search branch frame: ' .. tostring(frame.kind), 0)
end

local function prepare_alternative(state, frame, alt)
  local profile_plan = state.profile_plan
  if alt.kind == 'choice' then
    if profile_plan then
      profile_plan.choice_branches = profile_plan.choice_branches + 1
    end
    local task = state.tasks[frame.task_id]
    setv(state, task, 'expr', frame.expr.choices[alt.choice_index])
    setv(state, task, 'activation', Path.child(frame.activation, 'choice:' .. tostring(alt.choice_index)))
    add_active(state, task.id)
    return true
  elseif alt.kind == 'or_else_preferred' then
    if profile_plan then
      profile_plan.preferred_branches = profile_plan.preferred_branches + 1
      state.runtime.instrumentation:event(profile_plan, 'or_else_preferred')
    end
    local task = state.tasks[frame.task_id]
    setv(state, task, 'expr', frame.expr.p)
    setv(state, task, 'activation', Path.child(frame.activation, 'or_else:preferred'))
    add_active(state, task.id)
    return true
  elseif alt.kind == 'or_else_fallback' then
    if profile_plan then
      profile_plan.fallback_branches = profile_plan.fallback_branches + 1
      state.runtime.instrumentation:event(profile_plan, 'or_else_fallback')
    end
    setv(state, state, 'used_fallback', true)
    local pref = frame.preferred_certificate
    Certificate.each(pref, 'check', function(check)
      pushv(state, state.negative_checks, check)
    end)
    Certificate.each(pref, 'interest', function(interest)
      pushv(state, state.fallback_interests, interest)
    end)
    local task = state.tasks[frame.task_id]
    setv(state, task, 'expr', frame.expr.q)
    setv(
      state,
      task,
      'activation',
      Path.child(frame.activation, 'or_else:fallback:' .. Certificate.activation_label(pref))
    )
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
          local transition = intent and intent.program and intent.program.transition
          names[i] = (transition and transition.name)
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

local function branch_child_result(state, frame, outcome, candidate, certificate)
  if frame.kind == 'choice' then
    if outcome == 'hit' then
      local chosen = frame.order[frame.next_index - 1]
      local defeats = {}
      for i = 1, #(frame.expr.choices or {}) do
        if i ~= chosen then
          collect_defeat_effects(frame.expr.choices[i], defeats)
        end
      end
      candidate = attach_candidate_effects(state.runtime, candidate, defeats)
      if candidate then
        return 'done', 'hit', candidate, nil
      end
      return 'continue'
    end
    frame.certificate = Certificate.merge(frame.certificate, certificate)
    return 'continue'
  elseif frame.kind == 'or_else' then
    if outcome == 'hit' then
      return 'done', 'hit', candidate, nil
    end
    if frame.phase == 'preferred_running' then
      frame.preferred_certificate = certificate
      frame.phase = 'fallback'
      return 'continue'
    end
    return 'done', 'retry', nil, certificate or Certificate.new()
  elseif frame.kind == 'domain' then
    if outcome == 'hit' then
      return 'done', 'hit', candidate, nil
    end
    frame.certificate = Certificate.merge(frame.certificate, certificate)
    return 'continue'
  end
  error('unknown branch result frame: ' .. tostring(frame.kind), 0)
end

local function exhausted_branch_result(state, frame)
  if frame.kind == 'choice' then
    return frame.certificate or terminal_certificate(state)
  elseif frame.kind == 'or_else' then
    -- Both phases normally complete directly from branch_child_result.  This
    -- fallback protects malformed frames without changing user-visible facts.
    return frame.preferred_certificate or Certificate.new()
  elseif frame.kind == 'domain' then
    return Certificate.merge(frame.certificate, terminal_certificate(state))
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
      return finish_node(session, 'retry', nil, exhausted_branch_result(state, frame))
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

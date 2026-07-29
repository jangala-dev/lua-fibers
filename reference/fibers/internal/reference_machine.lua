-- Copy-on-branch semantic reference evaluator.
-- Kept outside the active kernel for differential testing.

local Op = require('fibers.op')
local Store = require('fibers.internal.reference_store')
local IR = require('fibers.internal.kernel.ir')
local ChoiceOrder = require('fibers.internal.kernel.choice_order')
local Frontier = require('fibers.internal.reference_domain')
local Activation = require('fibers.internal.reference_path')
local Certificate = require('fibers.internal.kernel.certificate')

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

local function new_outcome(task, packed, wrap)
  return { pack = packed, wrap = wrap, activation = task and task.activation or nil }
end

local function object_version_label(value)
  if value == nil then
    return '-'
  end
  return tostring(value.id or value) .. '@' .. tostring(value.version or '')
end

local function advance_activation(task, fact)
  task.activation = Activation.child(task.activation, fact)
end

local function intent_activation_label(intent)
  local program = intent.program or {}
  return Activation.label(intent.activation) .. '@' .. object_version_label(program.location)
end

local function copy_array(xs)
  local out = {}
  for i = 1, #(xs or {}) do
    out[i] = xs[i]
  end
  return out
end

local function copy_gate(gate)
  return gate and { checks = copy_array(gate.checks) } or nil
end

local function copy_map(xs)
  local out = {}
  for k, v in pairs(xs or {}) do
    out[k] = v
  end
  return out
end

local function map_count(xs)
  local n = 0
  for _ in pairs(xs or {}) do
    n = n + 1
  end
  return n
end

local function copy_scope_path(path)
  local out = {}
  for i = 1, #(path or {}) do
    local e = path[i]
    out[i] = { group_id = e.group_id, mode = e.mode, lane = e.lane }
  end
  return out
end

local function copy_frames(frames)
  local out = {}
  for i = 1, #(frames or {}) do
    local f = frames[i]
    local c = {}
    for k, v in pairs(f) do
      c[k] = v
    end
    out[i] = c
  end
  return out
end

local function rebuild_intent_indexes(state)
  state.intent_by_id = {}
  for i = 1, #(state.intents or {}) do
    local intent = state.intents[i]
    state.intent_by_id[intent.id] = intent
  end
end

local function clone_state(s)
  s.runtime.stats.state_clones = s.runtime.stats.state_clones + 1
  local out = {
    runtime = s.runtime,
    requests = s.requests,
    focus = s.focus,
    tasks = {},
    active = copy_array(s.active),
    roots = {},
    groups = {},
    segments = {},
    intents = {},
    intent_by_id = {},
    effects = copy_array(s.effects),
    absence_gate = copy_gate(s.absence_gate),
    excluded_roots = copy_map(s.excluded_roots),
    next_task = s.next_task,
    next_group = s.next_group,
    next_segment = s.next_segment,
    next_intent = s.next_intent,
    next_machine_serial = s.next_machine_serial,
    search_steps = s.search_steps,
    search_work = s.search_work,
    search_limit = s.search_limit,
    profile_plan = s.profile_plan,
    component = s.component,
    plan_id = s.plan_id,
  }

  for id, t in pairs(s.tasks) do
    out.tasks[id] = {
      id = t.id,
      root_id = t.root_id,
      expr = t.expr,
      frames = copy_frames(t.frames),
      segment_id = t.segment_id,
      scope_path = copy_scope_path(t.scope_path),
      status = t.status,
      choice_serial = t.choice_serial,
      symmetry_key = t.symmetry_key,
      activation = t.activation,
    }
  end

  for id, r in pairs(s.roots) do
    out.roots[id] = {
      request = r.request,
      segment_id = r.segment_id,
      done = r.done,
      outcome = r.outcome,
    }
  end

  for id, g in pairs(s.groups) do
    local lane_outcomes = {}
    for i = 1, g.count do
      lane_outcomes[i] = g.lane_outcomes[i]
    end
    out.groups[id] = {
      id = g.id,
      parent_task = g.parent_task,
      parent_segment = g.parent_segment,
      mode = g.mode,
      count = g.count,
      lane_segments = copy_array(g.lane_segments),
      lane_outcomes = lane_outcomes,
      completed = g.completed,
      activation = g.activation,
    }
  end

  for id, v in pairs(s.segments) do
    local cloned = Store.clone_segment(v)
    cloned.scope_path = copy_scope_path(v.scope_path)
    out.segments[id] = cloned
  end
  for id, v in pairs(s.segments) do
    if v.parent then
      out.segments[id].parent = out.segments[v.parent.id]
    end
  end

  for i = 1, #s.intents do
    out.intents[i] = Store.copy_intent(s.intents[i])
  end
  rebuild_intent_indexes(out)
  return out
end

local function new_segment(state, root_id, scope_path, source_segment_id)
  state.next_segment = state.next_segment + 1
  local id = state.next_segment
  local source = source_segment_id and state.segments[source_segment_id] or nil
  state.segments[id] = Store.new_segment(root_id, copy_scope_path(scope_path), source, id)
  return id
end

local function merge_group_views(state, group)
  local parent = state.segments[group.parent_segment]
  local children = {}
  for i = 1, group.count do
    children[i] = state.segments[group.lane_segments[i]]
  end
  return Store.join_segments(parent, children, group.mode)
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
  local has_wrap = false
  for i = 1, #lane_outcomes do
    if lane_outcomes[i] and lane_outcomes[i].wrap then
      has_wrap = true
      break
    end
  end
  if not has_wrap then
    return nil
  end

  return function(packed)
    local rows = packed[1]
    for i = 1, #lane_outcomes do
      local lane = lane_outcomes[i]
      if lane.wrap then
        rows[i] = lane.wrap(rows[i])
      end
    end
    return pack_(rows)
  end
end

local function add_active(state, task_id)
  local task = state.tasks[task_id]
  task.status = 'active'
  state.active[#state.active + 1] = task_id
end

local complete_task

local function finish_group_lane(state, task, frame, outcome)
  local group = state.groups[frame.group_id]
  group.lane_outcomes[frame.lane] = outcome
  group.completed = group.completed + 1
  task.status = 'done'

  if group.completed < group.count then
    return true
  end
  if not merge_group_views(state, group) then
    return false
  end

  local rows = { _fibers_rows = true }
  for i = 1, group.count do
    rows[i] = group.lane_outcomes[i].pack
  end
  local parent = state.tasks[group.parent_task]
  local activation_parts = {}
  for i = 1, group.count do
    activation_parts[i] = Activation.label(group.lane_outcomes[i].activation)
  end
  parent.activation =
    Activation.child(group.activation, 'product:result:' .. table.concat(activation_parts, ','))
  parent.status = 'active'
  return complete_task(state, parent, new_outcome(parent, pack_(rows), product_wrap(group.lane_outcomes)))
end

local function verify_continuation_dependencies(state, frame, next_op)
  if not state.runtime.verify_dependencies or frame.continuation_footprint == nil then
    return
  end
  local declared = IR.metadata_hint(frame.continuation_footprint)
  local actual = IR.metadata(next_op)
  local ok, reason = IR.metadata_covers(declared, actual)
  if not ok then
    error('continuation dependency declaration is incomplete: ' .. tostring(reason), 0)
  end
end

complete_task = function(state, task, outcome)
  while true do
    local n = #task.frames
    if n == 0 then
      local root = state.roots[task.root_id]
      root.done = true
      root.outcome = outcome
      task.status = 'done'
      return true
    end

    local frame = task.frames[n]
    task.frames[n] = nil

    if frame.kind == 'bind' then
      if outcome.wrap then
        error('transactional continuation attempted to consume a wrapped result', 0)
      end
      if frame.phase == 'map' then
        task.expr = Op.always(
          state.runtime:_call_in_phase('map', 'callback_error', frame.fn, unpack_pack(outcome.pack))
        )
      else
        local next_op =
          state.runtime:_call_in_phase('and_then', 'callback_error', frame.fn, unpack_pack(outcome.pack))
        if not Op.is_op(next_op) then
          error('and_then callback must return an Op', 0)
        end
        verify_continuation_dependencies(state, frame, next_op)
        task.expr = next_op
        task.activation =
          Activation.child(frame.activation, 'and_then:result:' .. Activation.label(outcome.activation))
      end
      add_active(state, task.id)
      return true
    elseif frame.kind == 'wrap' then
      outcome = new_outcome(task, outcome.pack, compose_wrap(outcome.wrap, frame.fn))
    elseif frame.kind == 'symmetry_restore' then
      task.symmetry_key = frame.previous_symmetry
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
    request.activation_root = Activation.new_request(request.id or root_id)
  end

  local segment_id = new_segment(state, root_id, {})
  state.next_task = state.next_task + 1
  local task_id = state.next_task
  state.tasks[task_id] = {
    id = task_id,
    root_id = root_id,
    expr = request.op,
    frames = {},
    segment_id = segment_id,
    scope_path = {},
    status = 'active',
    choice_serial = 0,
    symmetry_key = nil,
    activation = request.activation_root,
  }
  state.roots[root_id] = {
    request = request,
    segment_id = segment_id,
    done = false,
    scope = scope,
    scope_stack = scope and { scope } or {},
  }
  state.active[#state.active + 1] = task_id
end

local function start_product(state, task, op)
  state.next_group = state.next_group + 1
  local group_id = state.next_group
  local group = {
    id = group_id,
    parent_task = task.id,
    parent_segment = task.segment_id,
    mode = op.mode,
    count = #op.lanes,
    lane_segments = {},
    lane_outcomes = {},
    completed = 0,
    activation = task.activation,
  }
  state.groups[group_id] = group
  task.status = 'waiting_group'

  for i = 1, #op.lanes do
    local path = copy_scope_path(task.scope_path)
    path[#path + 1] = { group_id = group_id, mode = op.mode, lane = i }
    local segment_id = new_segment(state, task.root_id, path, task.segment_id)
    group.lane_segments[i] = segment_id
    state.next_task = state.next_task + 1
    local child_id = state.next_task
    state.tasks[child_id] = {
      id = child_id,
      root_id = task.root_id,
      expr = op.lanes[i],
      frames = { { kind = 'group_lane', group_id = group_id, lane = i } },
      segment_id = segment_id,
      scope_path = path,
      status = 'active',
      choice_serial = 0,
      symmetry_key = task.symmetry_key,
      activation = Activation.child(task.activation, 'product:lane:' .. tostring(i)),
    }
    state.active[#state.active + 1] = child_id
  end
end

local function same_root_compatible(a, b)
  local pa, pb = a.scope_path, b.scope_path
  local n = math.min(#pa, #pb)
  for i = 1, n do
    local x, y = pa[i], pb[i]
    if x.group_id ~= y.group_id then
      return false
    end
    if x.lane ~= y.lane then
      return x.mode == 'interacting'
    end
  end
  return false
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
    remove[ids[i]] = true
    state.intent_by_id[ids[i]] = nil
  end
  local kept = {}
  for i = 1, #state.intents do
    if not remove[state.intents[i].id] then
      kept[#kept + 1] = state.intents[i]
    end
  end
  state.intents = kept
end

local function result_pack(program, value)
  return IR.result_pack(program, value)
end

local function block_intent(state, task, occurrence)
  local program = occurrence.program
  state.next_intent = state.next_intent + 1
  task.status = 'blocked'
  local intent = {
    id = state.next_intent,
    kind = programme_kind(program),
    task_id = task.id,
    root_id = task.root_id,
    program = program,
    payload = occurrence.payload,
    activation = task.activation,
    resource = program.resource,
    role = program.role,
    value = occurrence.value,
    symmetry_key = task.symmetry_key,
    scope_path = copy_scope_path(task.scope_path),
    interest = type(program.interest) == 'function' and program.interest(state.runtime, program)
      or program.interest,
    absence_check = program.absence_check,
  }
  state.intents[#state.intents + 1] = intent
  state.intent_by_id[intent.id] = intent
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
  local labels = { Activation.label(a.activation), Activation.label(b.activation) }
  table.sort(labels)
  local fact = 'exchange:' .. table.concat(labels, '+')
  put_task.activation = Activation.child(put_task.activation, fact)
  get_task.activation = Activation.child(get_task.activation, fact)
  if not complete_task(state, put_task, new_outcome(put_task, PACK_TRUE)) then
    return false
  end
  if not complete_task(state, get_task, new_outcome(get_task, pack_(put.value))) then
    return false
  end
  return true
end

local function transition_context(state)
  return {
    runtime = state.runtime,
    now = function()
      return state.runtime:now()
    end,
  }
end

local function transition_ready(state, program, value, payload)
  return IR.transition_ready(program, value, transition_context(state), payload)
end

local function transition_outcome(state, program, value, phase, payload)
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
    Store.stage(state.segments[task.segment_id], program.location, patch)
  else
    Store.cell(state.segments[task.segment_id], program.location)
  end
end

local function transition_activation(selected)
  local labels = {}
  for i = 1, #selected do
    labels[i] = intent_activation_label(selected[i])
  end
  table.sort(labels)
  return 'transition:' .. table.concat(labels, '+')
end

local function finish_transitions(state, selected, resolved)
  local ids, fact = {}, transition_activation(selected)
  for i = 1, #selected do
    ids[i] = selected[i].id
  end
  remove_intent_ids(state, ids)
  for i = 1, #resolved do
    local row = resolved[i]
    row.task.activation = Activation.child(row.task.activation, fact)
    if not complete_task(state, row.task, new_outcome(row.task, row.result)) then
      return false
    end
  end
  return true
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

local function resolve_serial_transitions(state, selected)
  table.sort(selected, function(left, right)
    local a, b = IR.rule(left.program).order, IR.rule(right.program).order
    return a ~= b and a < b or a == b and (left.id or 0) < (right.id or 0)
  end)
  local resolved = {}
  for i = 1, #selected do
    local intent, program = selected[i], selected[i].program
    local task, rule = state.tasks[intent.task_id], IR.rule(program)
    local value = Store.project_machine(state, task, program.location, function(candidate)
      return transition_ready(state, program, candidate, intent.payload)
    end, rule.accepts_supply)
    local outcome = transition_outcome(state, program, value, nil, intent.payload)
    if not outcome then
      return false
    end
    stage_outcome(state, task, program, outcome)
    resolved[#resolved + 1] = { task = task, result = outcome.result }
  end
  return finish_transitions(state, selected, resolved)
end

local function resolve_transitions(state, intent_ids)
  local selected = selected_intents(state, intent_ids)
  if #selected == 0 then
    return false
  end
  if IR.rule(selected[1].program).serial then
    return resolve_serial_transitions(state, selected)
  end
  local resolved, remaining = {}, copy_array(selected)
  while #remaining > 0 do
    local chosen_index, chosen_outcome, chosen_task
    for i = 1, #remaining do
      local intent, program = remaining[i], remaining[i].program
      local task = state.tasks[intent.task_id]
      local value = Store.project(state, task, program.location, program.orientation)
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
  local value = Store.project_machine(state, task, program.location, function(candidate)
    return transition_ready(state, program, candidate, intent.payload)
  end, rule.accepts_supply)
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
  task.activation = Activation.child(
    task.activation,
    'witness:' .. intent_activation_label(intent) .. ':' .. tostring(alternative_index or 1)
  )
  local packed = outcome.result
  if not (type(packed) == 'table' and packed._fibers_pack == true) then
    if type(packed) == 'table' and packed.n ~= nil then
      packed._fibers_pack = true
    else
      packed = pack_(packed)
    end
  end
  return complete_task(state, task, new_outcome(task, packed))
end

local function resolve_claim_set(state, group, ids)
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
  local participants = {}
  for id in pairs(state.roots) do
    participants[#participants + 1] = id
  end
  table.sort(participants)
  for i = 1, #participants do
    if not state.roots[participants[i]].done then
      return nil
    end
  end
  if #state.intents > 0 then
    return nil
  end

  local root_views = {}
  for i = 1, #participants do
    root_views[i] = state.segments[state.roots[participants[i]].segment_id]
  end
  local observations, writes, collect_err = Store.collect_candidate(root_views)
  if collect_err then
    return nil
  end

  -- Domain constraints are fixed substrate rules, not resource callbacks.
  for loc, patch in pairs(writes or {}) do
    if loc.domain == 'counter' then
      local final = Store.apply_patch_value(loc, loc.value, patch)
      local owner = loc.owner
      if owner.min ~= nil and final < owner.min then
        return nil
      end
      if owner.max ~= nil and final > owner.max then
        return nil
      end
    end
  end

  local outcomes = {}
  for i = 1, #participants do
    local id = participants[i]
    outcomes[id] = state.roots[id].outcome
  end

  local absence_gate = Certificate.stamp_absence_gate(state.absence_gate, state.runtime)
  local candidate = {
    focus = state.focus,
    participants = participants,
    outcomes = outcomes,
    observations = observations,
    writes = writes,
    effects = #state.effects > 0 and copy_array(state.effects) or nil,
    absence_gate = absence_gate,
    search_steps = state.search_steps,
  }

  -- Effect merge and preparation are part of world admissibility. A structured
  -- refusal therefore rejects this derivation and lets ordinary search
  -- backtrack to another choice, partner or fallback world.
  local prepared = state.runtime:_prepare_hit_effects(candidate)
  if not prepared then
    return nil
  end
  candidate.prepared_effects = prepared
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
    local view = state.segments[task.segment_id]
    local value = program.observation.collect(resource, function(location)
      return Store.read(view, location)
    end)
    advance_activation(task, 'primitive:observe:' .. object_version_label(resource))
    return complete_task(state, task, new_outcome(task, IR.result_pack(program, value)))
  end

  local view = state.segments[task.segment_id]
  local loc = program.location

  if kind == 'version_wait' then
    local version = occurrence.version
    if loc.version ~= version then
      Store.cell(view, loc)
      advance_activation(task, 'primitive:version_wait:' .. object_version_label(loc))
      return complete_task(state, task, new_outcome(task, pack_(Store.read(view, loc), loc.version)))
    end
    program.observed_version = loc.version
    block_intent(state, task, occurrence)
    return true
  end

  if kind == 'read' then
    advance_activation(task, 'primitive:read:' .. object_version_label(loc))
    return complete_task(state, task, new_outcome(task, result_pack(program, Store.read(view, loc))))
  end

  if kind == 'patch' then
    local patch = occurrence.patch
    Store.stage(view, loc, patch)
    advance_activation(task, 'primitive:patch:' .. object_version_label(loc))
    return complete_task(state, task, new_outcome(task, result_pack(program, Store.read(view, loc))))
  end

  if kind == 'transition' then
    local rule = IR.rule(program)
    if rule.eager then
      local value = Store.read(view, loc)
      local outcome = transition_outcome(state, program, value, 'eager', occurrence.payload)
      if outcome then
        stage_outcome(state, task, program, outcome)
        advance_activation(task, 'primitive:transition:' .. object_version_label(loc))
        return complete_task(state, task, new_outcome(task, outcome.result))
      end
    end
    block_intent(state, task, occurrence)
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

local function terminal_refutation(state)
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
  candidate.effects = candidate.effects or {}
  for i = 1, #extra do
    candidate.effects[#candidate.effects + 1] = extra[i]
  end
  local prepared = runtime:_prepare_hit_effects(candidate)
  if not prepared then
    return nil
  end
  candidate.prepared_effects = prepared
  return candidate
end

local dfs

dfs = function(state)
  state.runtime.stats.search_calls = state.runtime.stats.search_calls + 1
  local profile_plan = state.profile_plan
  if profile_plan then
    profile_plan.search_calls = profile_plan.search_calls + 1
  end
  state.search_work.steps = state.search_work.steps + 1
  state.search_steps = state.search_work.steps
  if state.search_steps > state.search_limit then
    return nil, Certificate.new(), true
  end

  while true do
    if #state.active > 0 then
      local task_id = table.remove(state.active, 1)
      local task = state.tasks[task_id]
      if task.status ~= 'active' then
        -- A cloned queue may retain a task which completed through another lane.
      else
        if profile_plan then
          profile_plan.task_steps = profile_plan.task_steps + 1
        end
        if profile_plan then
          profile_plan.deterministic_steps = profile_plan.deterministic_steps + 1
        end
        local expr = task.expr
        local kind = expr.kind

        if kind == 'always' then
          if not complete_task(state, task, new_outcome(task, expr.vals)) then
            return nil, terminal_refutation(state), false
          end
        elseif kind == 'guard' then
          local parent_activation = task.activation
          local request = state.roots[task.root_id].request
          local residual = request.guard_residuals[parent_activation]
          if not residual then
            residual = state.runtime:_guard_residual(request, expr, parent_activation, true)
          end
          task.expr = residual
          task.activation = Activation.child(parent_activation, 'guard:result')
          add_active(state, task.id)
        elseif kind == 'and_then' then
          local parent_activation = task.activation
          task.frames[#task.frames + 1] = {
            kind = 'bind',
            fn = expr.fn,
            phase = expr.callback_phase,
            activation = parent_activation,
            continuation_footprint = expr.continuation_footprint,
          }
          task.expr = expr.p
          task.activation = Activation.child(parent_activation, 'and_then:prefix')
          add_active(state, task.id)
        elseif kind == 'annotated' then
          local parent_activation = task.activation
          if expr.post then
            task.frames[#task.frames + 1] = { kind = 'wrap', fn = expr.post }
          end
          if expr.symmetry_key ~= nil then
            task.frames[#task.frames + 1] =
              { kind = 'symmetry_restore', previous_symmetry = task.symmetry_key }
            task.symmetry_key = expr.symmetry_key
          end
          task.expr = expr.p
          task.activation = Activation.child(parent_activation, 'annotated:body')
          add_active(state, task.id)
        elseif kind == 'consequence' then
          state.effects[#state.effects + 1] = expr.effect
          if not complete_task(state, task, new_outcome(task, pack_())) then
            return nil, terminal_refutation(state), false
          end
        elseif kind == 'primitive' then
          if not execute_program(state, task, expr) then
            return nil, terminal_refutation(state), false
          end
        elseif kind == 'product' then
          start_product(state, task, expr)
        elseif kind == 'choice' then
          local refutation
          task.choice_serial = (task.choice_serial or 0) + 1
          local order = ChoiceOrder.indices(
            state.runtime,
            task,
            task.choice_serial,
            #(expr.choices or {}),
            state.choice_generation
          )
          for k = 1, #order do
            local i = order[k]
            local branch = clone_state(state)
            local bt = branch.tasks[task.id]
            bt.expr = expr.choices[i]
            bt.activation = Activation.child(task.activation, 'choice:' .. tostring(i))
            add_active(branch, bt.id)
            local found, ref, unknown = dfs(branch)
            if found then
              local defeats = {}
              for j = 1, #(expr.choices or {}) do
                if j ~= i then
                  collect_defeat_effects(expr.choices[j], defeats)
                end
              end
              found = attach_candidate_effects(state.runtime, found, defeats)
              if found then
                return found
              end
            end
            refutation = Certificate.merge(refutation, ref)
            if unknown then
              return nil, refutation, true
            end
          end
          return nil, refutation or terminal_refutation(state), false
        elseif kind == 'or_else' then
          local primary = clone_state(state)
          local pt = primary.tasks[task.id]
          pt.expr = expr.p
          pt.activation = Activation.child(task.activation, 'or_else:preferred')
          add_active(primary, pt.id)
          local found, pref, unknown = dfs(primary)
          if found then
            return found
          end
          if unknown then
            return nil, pref, true
          end

          local fallback = clone_state(state)
          local gate = fallback.absence_gate or Certificate.new_absence_gate()
          fallback.absence_gate = gate
          Certificate.each(pref, 'check', function(check)
            gate.checks[#gate.checks + 1] = check
          end)
          local ft = fallback.tasks[task.id]
          ft.expr = expr.q
          ft.activation =
            Activation.child(task.activation, 'or_else:fallback:' .. Certificate.gate_epoch(pref))
          add_active(fallback, ft.id)
          local fallback_found, fref, funknown = dfs(fallback)
          if fallback_found then
            return fallback_found
          end
          -- Once certified primary retry opens the residual fallback, the
          -- expression's own wake frontier is the fallback's frontier. The
          -- primary refutation remains only as a negative guard on a
          -- successful fallback candidate; retaining its interests after the
          -- fallback also retries would spuriously keep the whole expression
          -- pending.
          return nil, fref or Certificate.new(), funknown
        else
          error('unsupported Op kind: ' .. tostring(kind), 0)
        end
      end
    else
      local candidate = final_candidate(state)
      if candidate then
        return candidate
      end
      local refutation

      local frontier = Frontier.analyse(state, intents_compatible, true)
      local exchange = frontier.exchange
      if profile_plan then
        profile_plan.intent_pairs_scanned = profile_plan.intent_pairs_scanned + exchange.scans
        profile_plan.compatible_pairs = profile_plan.compatible_pairs + exchange.compatible
        profile_plan.exchange_domains = profile_plan.exchange_domains + (exchange.selected and 1 or 0)
        profile_plan.zero_exchange_domains = profile_plan.zero_exchange_domains + exchange.zero_domains
        profile_plan.max_exchange_domain =
          math.max(profile_plan.max_exchange_domain or 0, exchange.selected_degree or 0)
        profile_plan.symmetry_exchange_pruned = profile_plan.symmetry_exchange_pruned
          + (exchange.symmetry_pruned or 0)
      end
      if
        state.runtime.normalise_search ~= false
        and #state.intents == 2
        and exchange.selected_degree == 1
        and #exchange.pairs == 1
      then
        if not has_supplier(state, { exchange.selected }) then
          if profile_plan then
            profile_plan.forced_exchange_opportunities = profile_plan.forced_exchange_opportunities + 1
            profile_plan.forced_exchanges = profile_plan.forced_exchanges + 1
            profile_plan.normalisation_rounds = profile_plan.normalisation_rounds + 1
          end
          local branch = clone_state(state)
          local pair = exchange.pairs[1]
          if match_intents(branch, pair.left, pair.right) then
            return dfs(branch)
          end
          return nil, terminal_refutation(state), false
        end
      end
      for pi = 1, #exchange.pairs do
        local pair = exchange.pairs[pi]
        local branch = clone_state(state)
        if match_intents(branch, pair.left, pair.right) then
          local found, ref, unknown = dfs(branch)
          if found then
            return found
          end
          refutation = Certificate.merge(refutation, ref)
          if unknown then
            return nil, refutation, true
          end
        end
      end

      for ii = 1, #frontier.witnesses do
        local intent = frontier.witnesses[ii]
        do
          local cursor = witness_cursor(state, intent)
          while true do
            local alt = cursor:next()
            if alt == nil then
              break
            end
            local branch = clone_state(state)
            if resolve_witness(branch, intent.id, alt) then
              local found, ref, unknown = dfs(branch)
              if found then
                return found
              end
              refutation = Certificate.merge(refutation, ref)
              if unknown then
                return nil, refutation, true
              end
            end
          end
        end
      end

      local groups = frontier.claims
      for gi = 1, #groups do
        local group = groups[gi]
        local all_machine, machine_accepts_supply = group.all_machine, group.accepts_supply

        if all_machine and not machine_accepts_supply then
          local forced = false
          if state.runtime.normalise_search ~= false and #groups == 1 and #group.ids == #state.intents then
            local group_intents = {}
            for ii = 1, #group.ids do
              group_intents[ii] = state.intent_by_id[group.ids[ii]]
            end
            forced = not has_supplier(state, group_intents)
          end
          -- Non-supplying serial transducers have an explicit deterministic
          -- order and can be resolved as one location journal. This avoids
          -- factorially re-enumerating Lifetime and policy updates.
          local branch = clone_state(state)
          if forced and profile_plan then
            profile_plan.forced_claim_opportunities = profile_plan.forced_claim_opportunities + 1
            profile_plan.forced_claims = profile_plan.forced_claims + 1
            profile_plan.normalisation_rounds = profile_plan.normalisation_rounds + 1
          end
          if resolve_claim_set(branch, group, group.ids) then
            local found, ref, unknown = dfs(branch)
            if found then
              return found
            end
            refutation = Certificate.merge(refutation, ref)
            if unknown then
              return nil, refutation, true
            end
          end
        else
          -- A serial-transducer location has one deterministic transition
          -- order. Prefer resolving all currently entered transitions as one
          -- journal: this preserves cases such as two mailbox sends followed
          -- by a close in the same interacting product, where every sendability check must
          -- precede the close. If the complete journal is not admissible, retain
          -- the one-at-a-time alternatives needed for supplying hand-off and
          -- global backtracking (write/read, insert/pop, and similar cases).
          if all_machine and #group.ids > 1 then
            local whole = clone_state(state)
            if resolve_claim_set(whole, group, group.ids) then
              local found, ref, unknown = dfs(whole)
              if found then
                return found
              end
              refutation = Certificate.merge(refutation, ref)
              if unknown then
                return nil, refutation, true
              end
            end
          end

          -- Supplying machine transitions and ordinary claims may enable one
          -- another. Choose one next transition at a time so the evaluator can
          -- backtrack over execution order, while resolve_claim_set still folds
          -- unavoidable total updates in.
          for ii = 1, #group.ids do
            local branch = clone_state(state)
            if resolve_claim_set(branch, group, { group.ids[ii] }) then
              local found, ref, unknown = dfs(branch)
              if found then
                return found
              end
              refutation = Certificate.merge(refutation, ref)
              if unknown then
                return nil, refutation, true
              end
            end
          end
        end
      end

      local row, supplier_count = nil, 0
      if frontier.accepts_participant_supply then
        row, supplier_count = supplier_candidate(state)
      end
      if profile_plan then
        profile_plan.footprint_checks = profile_plan.footprint_checks
          + math.max(0, map_count(state.requests) - map_count(state.roots))
        profile_plan.recruitment_candidates = profile_plan.recruitment_candidates + supplier_count
        if row then
          profile_plan.recruitment_best_score =
            math.max(profile_plan.recruitment_best_score or 0, row.score or 0)
          profile_plan.footprint_matches = profile_plan.footprint_matches + supplier_count
          local key = 'footprint_' .. tostring(row.reason or 'unknown') .. '_matches'
          profile_plan[key] = (profile_plan[key] or 0) + 1
        end
      end
      if row then
        local included = clone_state(state)
        add_root(included, row.id)
        local found, ref, unknown = dfs(included)
        if found then
          return found
        end
        refutation = Certificate.merge(refutation, ref)
        if unknown then
          return nil, refutation, true
        end

        local excluded = clone_state(state)
        local equivalent_ids = row.equivalent_ids or { row.id }
        for i = 1, #equivalent_ids do
          excluded.excluded_roots[equivalent_ids[i]] = true
        end
        found, ref, unknown = dfs(excluded)
        if found then
          return found
        end
        refutation = Certificate.merge(refutation, ref)
        if unknown then
          return nil, refutation, true
        end
      end

      local terminal = terminal_refutation(state)
      refutation = Certificate.merge(refutation, terminal)
      return nil, refutation, false
    end
  end
end

function M.search(runtime, requests, focus_id, search_limit, component)
  if not requests[focus_id] then
    return nil
  end
  runtime.stats.plans = runtime.stats.plans + 1
  local instrumentation = runtime.instrumentation
  local profile_plan = instrumentation
      and instrumentation:begin_plan({
        focus = focus_id,
        pending = map_count(requests),
        machine = 'reference',
        total_pending = component and component.total or map_count(requests),
        component_size = component and component.size or map_count(requests),
        component_dynamic = component and component.dynamic or 0,
        component_global = component and component.global == true or false,
        component_edge_visits = component and component.edge_visits or 0,
      })
    or nil
  local state = {
    runtime = runtime,
    requests = requests,
    focus = focus_id,
    choice_generation = component and component.order_generation or nil,
    tasks = {},
    active = {},
    roots = {},
    groups = {},
    segments = {},
    intents = {},
    intent_by_id = {},
    effects = {},
    absence_gate = nil,
    excluded_roots = {},
    next_task = 0,
    next_group = 0,
    next_segment = 0,
    next_intent = 0,
    next_machine_serial = 0,
    search_steps = 0,
    search_work = { steps = 0 },
    search_limit = search_limit or runtime.search_limit,
    profile_plan = profile_plan,
    component = component,
  }
  add_root(state, focus_id)
  local candidate, refutation, unknown = dfs(state)
  state.search_steps = state.search_work.steps
  if candidate then
    runtime._last_search_steps = candidate.search_steps
  end
  if profile_plan then
    profile_plan.search_steps = state.search_steps
    if candidate then
      profile_plan.participants = #(candidate.participants or {})
      profile_plan.observations = map_count(candidate.observations)
      profile_plan.writes = map_count(candidate.writes)
      profile_plan.effects = #(candidate.effects or {})
    end
    instrumentation:finish_plan(profile_plan, candidate and 'found' or (unknown and 'unknown' or 'retry'))
  end
  return candidate, refutation, unknown
end

M.path = Activation
return M

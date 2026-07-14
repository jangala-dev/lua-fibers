-- Production trail-based proof-search evaluator.
-- The copy-on-branch oracle lives in reference/fibers/internal/reference_machine.lua.

local Op = require('fibers.op')
local Store = require('fibers.internal.kernel.store')
local IR = require('fibers.internal.kernel.ir')
local ChoiceOrder = require('fibers.internal.kernel.choice_order')
local Frontier = require('fibers.internal.kernel.frontier')
local SearchCache = require('fibers.internal.kernel.adaptive_search')
local SearchSession = require('fibers.internal.kernel.search_session')
local Activation = require('fibers.internal.kernel.activation')

local M = {}

local unpack_ = table.unpack or unpack
local pack_ = Op._pack
local function programme_kind(program)
  return program.program_kind or program.kind
end
local PACK_TRUE = pack_(true)

local function unpack_pack(p)
  return unpack_(p, 1, p.n or #p)
end

local function packv(state, ...)
  return state.session:pack(...)
end

local function new_outcome(state, packed, wrap, task)
  if
    task
    and #task.frames == 0
    and state.roots[task.root_id] == task
  then
    task.pack, task.wrap = packed, wrap
    return task
  end
  local outcome = state.session:acquire_record('outcome')
  outcome.pack, outcome.wrap, outcome.activation = packed, wrap, task and task.activation or nil
  return outcome
end

local function copy_array(xs)
  local out = {}
  for i = 1, #(xs or {}) do
    out[i] = xs[i]
  end
  return out
end

local function extend_scope_path(parent, group_id, mode, lane)
  return {
    _fibers_scope_path = true,
    parent = parent,
    depth = parent and (parent.depth + 1) or 1,
    group_id = group_id,
    mode = mode,
    lane = lane,
  }
end

local Trail = {}
Trail.__index = Trail

function Trail.new(stats, plan)
  return setmetatable({
    n = 0,
    kinds = {},
    targets = {},
    keys = {},
    olds = {},
    mark_ns = {},
    mark_parents = {},
    stats = stats,
    plan = plan,
    next_mark = 0,
    current_mark = 0,
  }, Trail)
end

function Trail:mark()
  local mark = self.next_mark + 1
  self.next_mark = mark
  self.mark_ns[mark] = self.n
  self.mark_parents[mark] = self.current_mark
  self.current_mark = mark
  return mark
end

local function add_entry(self, kind, target, key, old)
  local n = self.n + 1
  self.n = n
  self.kinds[n], self.targets[n], self.keys[n], self.olds[n] = kind, target, key, old
  if self.stats then
    self.stats.trail_entries = (self.stats.trail_entries or 0) + 1
  end
  local plan = self.plan
  if plan then
    plan.trail_entries = plan.trail_entries + 1
    if n > plan.max_trail then
      plan.max_trail = n
    end
  end
end

function Trail:set(target, key, value)
  if target[key] == value then
    return
  end
  -- Mutations made before the first speculative checkpoint are the plan's
  -- base state.  They can never be reached by rollback, so journalling them is
  -- pure overhead on deterministic and forced paths.
  if self.current_mark == 0 then
    target[key] = value
    return
  end
  add_entry(self, 1, target, key, target[key])
  target[key] = value
end

function Trail:push(target, value)
  if self.current_mark == 0 then
    target[#target + 1] = value
    return
  end
  add_entry(self, 2, target, nil, #target)
  target[#target + 1] = value
end

function Trail:rollback(mark)
  local mark_n = self.mark_ns[mark]
  local removed = self.n - mark_n
  for i = self.n, mark_n + 1, -1 do
    local kind, target, key, old = self.kinds[i], self.targets[i], self.keys[i], self.olds[i]
    if kind == 1 then
      target[key] = old
    elseif kind == 2 then
      for j = #target, old + 1, -1 do
        target[j] = nil
      end
    else
      error('unknown trail entry: ' .. tostring(kind), 0)
    end
    self.kinds[i], self.targets[i], self.keys[i], self.olds[i] = nil, nil, nil, nil
  end
  self.n = mark_n
  self.current_mark = self.mark_parents[mark] or 0
  self.mark_ns[mark], self.mark_parents[mark] = nil, nil
  if self.stats then
    self.stats.rollbacks = (self.stats.rollbacks or 0) + 1
  end
  local plan = self.plan
  if plan then
    plan.rollbacks = plan.rollbacks + 1
    plan.rollback_entries = plan.rollback_entries + removed
  end
end


function Trail:begin(stats, plan)
  if self.n ~= 0 or self.current_mark ~= 0 then
    error('cannot begin a search with a non-empty trail', 2)
  end
  self.stats = stats
  self.plan = plan
end

function Trail:reset(stats, plan)
  for i = self.n, 1, -1 do
    self.kinds[i], self.targets[i], self.keys[i], self.olds[i] = nil, nil, nil, nil
  end
  self.n = 0
  for i = self.next_mark, 1, -1 do
    self.mark_ns[i], self.mark_parents[i] = nil, nil
  end
  self.next_mark, self.current_mark = 0, 0
  if stats ~= nil then
    self.stats = stats
  end
  if plan ~= nil or self.plan ~= nil then
    self.plan = plan
  end
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
  setv(state, task, 'activation', Activation.child(task.activation, fact))
end

local function intent_activation_label(intent)
  local program = intent.program or {}
  return Activation.label(intent.activation)
    .. '@'
    .. object_version_label(program.location or program.group)
end

local function map_count(xs)
  local n = 0
  for _ in pairs(xs or {}) do
    n = n + 1
  end
  return n
end

local function new_view(state, root_id, scope_path, source_view_id)
  state.next_view = state.next_view + 1
  local id = state.next_view
  local source = source_view_id and state.views[source_view_id] or nil
  local view = state.session:acquire_record('view')
  setv(state, state.views, id, Store.new_view(root_id, scope_path, source, id, view))
  local profile_plan = state.profile_plan
  if profile_plan and state.next_view > profile_plan.max_views then
    profile_plan.max_views = state.next_view
  end
  return id
end

local function ensure_task_view(state, task)
  local view_id = task.view_id
  if view_id then
    return state.views[view_id], view_id
  end
  view_id = new_view(state, task.root_id, task.scope_path or {})
  setv(state, task, 'view_id', view_id)
  local root = state.roots[task.root_id]
  if root and root.task_id == task.id and root.view_id == nil then
    setv(state, root, 'view_id', view_id)
  end
  return state.views[view_id], view_id
end

local function merge_group_views(state, group)
  local parent = state.views[group.parent_view]
  local children = state.session:reuse_array('_arena_merge_children')
  for i = 1, group.count do
    children[i] = state.views[group.lane_views[i]]
  end
  return Store.merge_views(parent, children, group.mode, state.trail)
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
  if not merge_group_views(state, group) then
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
    activation_parts[i] = Activation.label(group.lane_outcomes[i].activation)
  end
  setv(
    state,
    parent,
    'activation',
    Activation.child(group.activation, 'product:result:' .. table.concat(activation_parts, ','))
  )
  setv(state, parent, 'status', 'active')
  return complete_task(
    state,
    parent,
    new_outcome(state, packv(state, rows), product_wrap(group.lane_outcomes), parent)
  )
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
            state.runtime:_call_in_phase(
              'map',
              'callback_error',
              frame.fn,
              unpack_pack(outcome.pack)
            )
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
            verify_continuation_dependencies(state, frame, cached)
            request.memo[frame.activation] = cached
          end
          setv(state, task, 'expr', cached)
          setv(state, task, 'activation', Activation.child(frame.activation, 'guard:result'))
        else
          local next_op = state.runtime:_call_in_phase(
            'and_then',
            'callback_error',
            frame.fn,
            unpack_pack(outcome.pack)
          )
          if not Op.is_op(next_op) then
            error('and_then callback must return an Op', 0)
          end
          verify_continuation_dependencies(state, frame, next_op)
          setv(state, task, 'expr', next_op)
          setv(
            state,
            task,
            'activation',
            Activation.child(
              frame.activation,
              'and_then:result:' .. Activation.label(outcome.activation)
            )
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
    request.activation_root = Activation.new_request(request.id or root_id)
  end

  state.next_task = state.next_task + 1
  local task_id = state.next_task
  -- The root and its initial evaluator task have identical lifetimes and no
  -- conflicting fields.  Use one strand record for both roles; product lanes
  -- and other child tasks remain ordinary task records.
  local task = state.session:acquire_record('task')
  task.id, task.root_id, task.expr = task_id, root_id, request.op
  task.activation = request.activation_root
  task.view_id, task.scope_path, task.status = nil, nil, 'active'
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
  local _, parent_view_id = ensure_task_view(state, task)
  group.id, group.parent_task, group.parent_view = group_id, task.id, parent_view_id
  group.activation = task.activation
  group.mode, group.count, group.completed = op.mode, #op.lanes, 0
  setv(state, state.groups, group_id, group)
  setv(state, task, 'status', 'waiting_group')

  local profile_plan = state.profile_plan
  if profile_plan then
    state.runtime.instrumentation:event(
      profile_plan,
      'product',
      { mode = op.mode, lanes = #op.lanes }
    )
  end
  for i = 1, #op.lanes do
    local path = extend_scope_path(task.scope_path, group_id, op.mode, i)
    local view_id = new_view(state, task.root_id, path, parent_view_id)
    setv(state, group.lane_views, i, view_id)
    state.next_task = state.next_task + 1
    local child_id = state.next_task
    local child = state.session:acquire_record('task')
    child.id, child.root_id, child.expr = child_id, task.root_id, op.lanes[i]
    child.activation = Activation.child(task.activation, 'product:lane:' .. tostring(i))
    child.frames[1] = { kind = 'group_lane', group_id = group_id, lane = i }
    child.view_id, child.scope_path, child.status = view_id, path, 'active'
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
  return Store.path_relation(a.root_id, a.scope_path, b.root_id, b.scope_path) == 'interacting'
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
    setv(state, state.intent_by_id, ids[i], nil)
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
  intent.activation = task.activation
  intent.resource, intent.role = program.resource or program.group, program.role
  intent.value = program.payload_field == 'value' and occurrence.payload or program.value
  intent.symmetry_key, intent.scope_path = task.symmetry_key, task.scope_path
  intent.interest = type(program.interest) == 'function'
      and program.interest(state.runtime, program)
    or program.interest
  intent.absence_check = program.absence_check
  pushv(state, state.intents, intent)
  setv(state, state.intent_by_id, intent.id, intent)
  local profile_plan = state.profile_plan
  if profile_plan then
    if #state.intents > profile_plan.max_intents then
      profile_plan.max_intents = #state.intents
    end
    state.runtime.instrumentation:event(profile_plan, 'intent', {
      program_kind = program.kind,
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
  local labels = { Activation.label(a.activation), Activation.label(b.activation) }
  table.sort(labels)
  local fact = 'exchange:' .. table.concat(labels, '+')
  setv(state, put_task, 'activation', Activation.child(put_task.activation, fact))
  setv(state, get_task, 'activation', Activation.child(get_task.activation, fact))
  if not complete_task(state, put_task, new_outcome(state, PACK_TRUE, nil, put_task)) then
    return false
  end
  if
    not complete_task(
      state,
      get_task,
      new_outcome(state, packv(state, put.value), nil, get_task)
    )
  then
    return false
  end
  return true
end

local function is_machine_wait(x)
  return x == require('fibers.scalar').Wait
    or (type(x) == 'table' and x._fibers_scalar_wait == true)
end

local function is_machine_ready(x)
  return type(x) == 'table' and x._fibers_scalar_ready == true
end

local function machine_context(state)
  return {
    runtime = state.runtime,
    now = function()
      return state.runtime:now()
    end,
  }
end

local function machine_probe(state, program, value)
  local profile_plan = state.profile_plan
  if profile_plan then
    profile_plan.machine_probes = profile_plan.machine_probes + 1
  end
  local t, payload = program.transition, program.payload or {}
  if type(t.ready) == 'function' then
    local out = t.ready(value, payload, machine_context(state))
    return out ~= nil and out ~= false and not is_machine_wait(out)
  end
  local packed = packv(state, t.step(value, payload, machine_context(state)))
  local first = packed[1]
  if packed.n == 1 and is_machine_wait(first) then
    return false
  end
  if is_machine_ready(first) then
    return true
  end
  if t.mode == 'update' then
    return packed.n > 0
  end
  return packed.n > 0 and packed[1] ~= nil
end

local function run_machine_transition(state, program, value)
  local profile_plan = state.profile_plan
  if profile_plan then
    profile_plan.machine_steps = profile_plan.machine_steps + 1
  end
  local t, payload = program.transition, program.payload or {}
  local packed = packv(state, t.step(value, payload, machine_context(state)))
  local first = packed[1]
  if packed.n == 1 and is_machine_wait(first) then
    return nil
  end
  if is_machine_ready(first) then
    if t.mode == 'query' and first.writes then
      return nil
    end
    return {
      writes = first.writes == true,
      value = first.value,
      result = first.pack or packv(state),
    }
  end
  if t.mode == 'update' then
    if packed.n == 0 then
      return nil
    end
    local out = { n = packed.n - 1 }
    for i = 2, packed.n do
      out[i - 1] = packed[i]
    end
    out._fibers_pack = true
    return { writes = true, value = packed[1], result = out }
  end
  if packed.n == 0 or packed[1] == nil then
    return nil
  end
  if t.mode == 'select' then
    local out = { n = packed.n - 1, _fibers_pack = true }
    for i = 2, packed.n do
      out[i - 1] = packed[i]
    end
    return { writes = true, value = packed[1], result = out }
  end
  return { writes = false, result = packed }
end

local function resolve_machine_transitions(state, selected)
  table.sort(selected, function(a, b)
    local ao = (a.program.order or 0) + ((a.id or 0) / 1000000)
    local bo = (b.program.order or 0) + ((b.id or 0) / 1000000)
    return ao < bo
  end)
  local proof_labels = {}
  for i = 1, #selected do
    proof_labels[i] = intent_activation_label(selected[i])
  end
  table.sort(proof_labels)
  local activation_fact = 'claim:' .. table.concat(proof_labels, '+')
  local resolved = {}
  for i = 1, #selected do
    local intent = selected[i]
    local program = intent.program
    local task = state.tasks[intent.task_id]
    ensure_task_view(state, task)
    local value = Store.project_machine(state, task, program.location, function(v)
      return machine_probe(state, program, v)
    end, program.transition.supply, state.trail)
    local r = run_machine_transition(state, program, value)
    if not r then
      return false
    end
    if r.writes then
      state.next_machine_serial = state.next_machine_serial + 1
      Store.stage(state.views[task.view_id], program.location, {
        kind = 'machine',
        steps = { { serial = state.next_machine_serial, value = r.value } },
      }, state.trail)
    else
      -- Ensure the location version is part of the observation set.
      Store.cell(state.views[task.view_id], program.location, state.trail)
    end
    resolved[#resolved + 1] = { intent = intent, task = task, result = r.result }
  end
  local ids = {}
  for i = 1, #selected do
    ids[i] = selected[i].id
  end
  remove_intent_ids(state, ids)
  for i = 1, #resolved do
    setv(
      state,
      resolved[i].task,
      'activation',
      Activation.child(resolved[i].task.activation, activation_fact)
    )
    if
      not complete_task(
        state,
        resolved[i].task,
        new_outcome(state, resolved[i].result, nil, resolved[i].task)
      )
    then
      return false
    end
  end
  return true
end

local function resolve_claims(state, intent_ids)
  local selected, by_id = {}, {}
  for i = 1, #intent_ids do
    by_id[intent_ids[i]] = true
  end
  for i = 1, #state.intents do
    local intent = state.intents[i]
    if by_id[intent.id] then
      selected[#selected + 1] = intent
    end
  end
  table.sort(selected, function(a, b)
    return a.id < b.id
  end)
  if #selected == 0 then
    return false
  end
  if selected[1].kind == 'machine_transition' then
    return resolve_machine_transitions(state, selected)
  end

  local proof_labels = {}
  for i = 1, #selected do
    proof_labels[i] = intent_activation_label(selected[i])
  end
  table.sort(proof_labels)
  local activation_fact = 'claim:' .. table.concat(proof_labels, '+')
  local resolved = {}
  for i = 1, #selected do
    local intent = selected[i]
    local program = intent.program
    local loc = program.location
    local task = state.tasks[intent.task_id]
    ensure_task_view(state, task)
    local value =
      Store.project(state, task, loc, program.orientation or program.demand_tag, state.trail)
    if value == nil then
      return false
    end
    local resolution = Store.evaluate_claim(program, value)
    if not resolution then
      return false
    end

    -- Stage immediately, but do not complete the task yet. Later claims see
    -- the mutation through the ordinary provenance rules.
    if resolution.patch then
      Store.stage(state.views[task.view_id], loc, resolution.patch, state.trail)
    end
    resolved[#resolved + 1] = {
      intent = intent,
      task = task,
      result = resolution.result,
    }
  end

  remove_intent_ids(state, intent_ids)
  for i = 1, #resolved do
    local r = resolved[i]
    setv(state, r.task, 'activation', Activation.child(r.task.activation, activation_fact))
    if not complete_task(state, r.task, new_outcome(state, r.result, nil, r.task)) then
      return false
    end
  end
  return true
end

local function witness_cursor(state, intent)
  local program = intent.program
  local task = state.tasks[intent.task_id]
  ensure_task_view(state, task)
  local function ready(value)
    return IR.witness_ready(program, value, program.payload or {}, {})
  end
  local value = Store.project_machine(
    state,
    task,
    program.location,
    ready,
    program.supply or 'interacting',
    state.trail
  )
  return IR.open_witness_cursor(program, value, program.payload or {}, {})
end

local function resolve_witness(state, intent_id, alt, alternative_index)
  local intent, intent_pos
  for i = 1, #state.intents do
    if state.intents[i].id == intent_id then
      intent, intent_pos = state.intents[i], i
      break
    end
  end
  if not intent or not alt then
    return false
  end
  local task = state.tasks[intent.task_id]
  if alt.writes ~= false then
    state.next_machine_serial = state.next_machine_serial + 1
    Store.stage(state.views[task.view_id], intent.program.location, {
      kind = 'machine',
      steps = { { serial = state.next_machine_serial, value = alt.value } },
    }, state.trail)
  else
    Store.cell(state.views[task.view_id], intent.program.location, state.trail)
  end
  local kept = {}
  for i = 1, #state.intents do
    if i ~= intent_pos then
      kept[#kept + 1] = state.intents[i]
    end
  end
  if state.trail then
    state.trail:set(state, 'intents', kept)
  else
    state.intents = kept
  end
  setv(
    state,
    task,
    'activation',
    Activation.child(
      task.activation,
      'witness:'
        .. intent_activation_label(intent)
        .. ':'
        .. tostring(alternative_index or 1)
    )
  )
  local packed = alt.result
  if not (type(packed) == 'table' and packed._fibers_pack == true) then
    if type(packed) == 'table' and packed.n ~= nil then
      packed._fibers_pack = true
    else
      packed = packv(state, packed)
    end
  end
  return complete_task(state, task, new_outcome(state, packed, nil, task))
end

local function resolve_claim_set(state, group, ids)
  -- Total machine updates on a location are unavoidable members of the
  -- current world.  Include them whenever resolving another transition on
  -- that location so a constraining sibling cannot be bypassed by resolving
  -- a partial subset first.
  local selected = {}
  for i = 1, #ids do
    selected[ids[i]] = true
  end
  for i = 1, #(group.ids or {}) do
    local id = group.ids[i]
    local intent = state.intent_by_id[id]
    if
      intent
      and intent.kind == 'machine_transition'
      and intent.program.transition.mode == 'update'
    then
      selected[id] = true
    end
  end
  local expanded = {}
  for id in pairs(selected) do
    expanded[#expanded + 1] = id
  end
  table.sort(expanded)
  return resolve_claims(state, expanded)
end

local function final_candidate(state)
  local root_count = state.root_count or 0
  if root_count <= 2 then
    if (state.root_1 and not state.root_1.done) or (state.root_2 and not state.root_2.done) then
      return nil
    end
  else
    for _, root in pairs(state.roots) do
      if not root.done then
        return nil
      end
    end
  end
  if #state.intents > 0 then
    return nil
  end

  local root_views = state.session:reuse_array('_arena_root_views')
  local only_root = root_count == 1 and state.root_1 or nil
  if root_count <= 2 then
    local root = state.root_1
    if root and root.view_id then
      root_views[#root_views + 1] = state.views[root.view_id]
    end
    root = state.root_2
    if root and root.view_id then
      root_views[#root_views + 1] = state.views[root.view_id]
    end
  else
    for _, root in pairs(state.roots) do
      if root.view_id then
        root_views[#root_views + 1] = state.views[root.view_id]
      end
    end
  end
  local store_view, observations, writes
  if root_count == 1 and only_root.view_id then
    store_view = state.views[only_root.view_id]
  else
    local collect_err
    observations, writes, collect_err = Store.collect_candidate(root_views)
    if collect_err then
      return nil
    end
  end

  -- Domain constraints are fixed substrate rules, not resource callbacks.
  local domain_writes = store_view and store_view.delta or writes
  for loc, patch in pairs(domain_writes or {}) do
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

  local participant_count = root_count
  local participant_1 = state.root_1 and state.root_1.root_id or nil
  local participant_2 = state.root_2 and state.root_2.root_id or nil
  local participants = nil
  if root_count > 2 then
    participant_count, participant_1, participant_2 = 0, nil, nil
    for id in pairs(state.roots) do
      participant_count = participant_count + 1
      if participant_count == 1 then
        participant_1 = id
      elseif participant_count == 2 then
        participant_2 = id
      else
        if not participants then
          participants = state.session:reuse_array('_arena_participants')
          participants[1], participants[2] = participant_1, participant_2
        end
        participants[participant_count] = id
      end
    end
  end
  if participants then
    table.sort(participants)
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
    store_view,
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
    plan.observations = map_count(store_view and store_view.cells or observations)
    plan.writes = map_count(store_view and store_view.delta or writes)
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

  if kind == 'snapshot' then
    local resource = program.resource
    local view = ensure_task_view(state, task)
    if program.snapshot_kind == 'keyed' then
      local entries, keys = {}, {}
      for k in pairs(resource.entries) do
        keys[k] = true
      end
      for k in pairs(resource._locations) do
        keys[k] = true
      end
      for k in pairs(keys) do
        local value = Store.read(view, resource:_location(k), state.trail)
        if value ~= Store.ABSENT then
          if resource._nil_sentinel and value == resource._nil_sentinel then
            entries[k] = nil
          else
            entries[k] = value
          end
        end
      end
      advance_activation(
        state,
        task,
        'primitive:snapshot:keyed:' .. object_version_label(resource)
      )
      return complete_task(
        state,
        task,
        new_outcome(
          state,
          packv(state, { entries = entries, version = resource.version }),
          nil,
          task
        )
      )
    elseif program.snapshot_kind == 'index' then
      local value = Store.read(view, resource._location, state.trail)
      local entries = {}
      for k, e in pairs(value or {}) do
        entries[k] = { key = e.key, rank = e.rank, value = e.value, seq = e.seq }
      end
      advance_activation(
        state,
        task,
        'primitive:snapshot:index:' .. object_version_label(resource)
      )
      return complete_task(
        state,
        task,
        new_outcome(
          state,
          packv(state, { entries = entries, version = resource.version }),
          nil,
          task
        )
      )
    elseif program.snapshot_kind == 'lease' then
      local holders = {}
      local subjects = {}
      for s in pairs(resource.holders or {}) do
        subjects[s] = true
      end
      for s in pairs(resource._locations or {}) do
        subjects[s] = true
      end
      for subject in pairs(subjects) do
        local loc = resource:_location(subject)
        local hs = Store.read(view, loc, state.trail)
        holders[subject] = {}
        for owner, mode in pairs(hs or {}) do
          holders[subject][owner] = mode
        end
      end
      advance_activation(
        state,
        task,
        'primitive:snapshot:lease:' .. object_version_label(resource)
      )
      return complete_task(
        state,
        task,
        new_outcome(
          state,
          packv(state, { holders = holders, version = resource.version }),
          nil,
          task
        )
      )
    end
    error('unknown snapshot kind', 0)
  end

  local view = nil
  local loc = program.location

  if kind == 'version_wait' then
    view = ensure_task_view(state, task)
    if loc.version ~= program.version then
      Store.cell(view, loc, state.trail)
      advance_activation(
        state,
        task,
        'primitive:version_wait:' .. object_version_label(loc)
      )
      return complete_task(
        state,
        task,
        new_outcome(
          state,
          packv(state, Store.read(view, loc, state.trail), loc.version),
          nil,
          task
        )
      )
    end
    program.observed_version = loc.version
    block_intent(state, task, program)
    return true
  end

  if kind == 'read' then
    view = ensure_task_view(state, task)
    advance_activation(state, task, 'primitive:read:' .. object_version_label(loc))
    return complete_task(
      state,
      task,
      new_outcome(
        state,
        Store.result_pack(program, Store.read(view, loc, state.trail), state.session),
        nil,
        task
      )
    )
  end

  if kind == 'patch' then
    view = ensure_task_view(state, task)
    local patch = program.patch
    if program.payload_patch == 'replace' then
      patch = { kind = 'replace', value = occurrence.payload }
    end
    Store.stage(view, loc, patch, state.trail)
    advance_activation(state, task, 'primitive:patch:' .. object_version_label(loc))
    return complete_task(
      state,
      task,
      new_outcome(
        state,
        Store.result_pack(program, Store.read(view, loc, state.trail), state.session),
        nil,
        task
      )
    )
  end

  if kind == 'claim' or kind == 'machine_transition' or kind == 'witness_transition' then
    block_intent(state, task, program)
    return true
  end

  if kind == 'conditional_claim' then
    view = ensure_task_view(state, task)
    local value = Store.read(view, loc, state.trail)
    if Store.predicate_holds(program, value) then
      Store.stage(view, loc, program.immediate_patch, state.trail)
      advance_activation(
        state,
        task,
        'primitive:conditional_claim:' .. object_version_label(loc)
      )
      return complete_task(
        state,
        task,
        new_outcome(state, Store.result_pack(program, value, state.session), nil, task)
      )
    end
    block_intent(state, task, program)
    return true
  end

  error('unknown programme kind: ' .. tostring(kind), 0)
end

local function search_work_steps(state)
  return state.search_work and state.search_work.steps or state.search_steps or 0
end

local function search_cache(state)
  return SearchCache.ensure(state)
end

local function has_supplier(state, intents)
  local enabled = state.refutation_cache_possible
    and search_work_steps(state) >= (state.refutation_cache_min_steps or 0)
    and SearchCache.supplier_enabled(search_cache(state), state)
  local signature = enabled and SearchCache.supplier_signature(state, intents) or nil
  local cache = signature and search_cache(state) or nil
  if signature and SearchCache.get_no_supplier(cache, signature) then
    return false
  end
  local found =
    state.runtime:_has_supplier(intents, state.roots, state.excluded_roots, state.requests)
  if not found and signature then
    SearchCache.put_no_supplier(cache, signature)
  end
  return found
end

local function supplier_rows(state)
  local enabled = state.refutation_cache_possible
    and search_work_steps(state) >= (state.refutation_cache_min_steps or 0)
    and SearchCache.supplier_enabled(search_cache(state), state)
  local signature = enabled and SearchCache.supplier_signature(state, state.intents) or nil
  local cache = signature and search_cache(state) or nil
  if signature and SearchCache.get_no_supplier(cache, signature) then
    return {}, true
  end
  local rows = state.runtime:_supplier_request_rows(
    state.intents,
    state.roots,
    state.excluded_roots,
    state.requests
  )
  if #rows == 0 and signature then
    SearchCache.put_no_supplier(cache, signature)
  end
  return rows, false
end

local function merge_refutation(dst, src)
  if not src then
    return dst
  end
  dst = dst or { interests = {}, checks = {}, activation_keys = {} }
  dst.activation_keys = dst.activation_keys or {}
  local seen_i, seen_c, seen_a = {}, {}, {}
  for i = 1, #dst.interests do
    seen_i[dst.interests[i].id or tostring(dst.interests[i])] = true
  end
  for i = 1, #dst.checks do
    seen_c[dst.checks[i].id or tostring(dst.checks[i])] = true
  end
  for i = 1, #dst.activation_keys do
    seen_a[dst.activation_keys[i]] = true
  end
  for i = 1, #(src.interests or {}) do
    local x = src.interests[i]
    local id = x.id or tostring(x)
    if not seen_i[id] then
      seen_i[id] = true
      dst.interests[#dst.interests + 1] = x
    end
  end
  for i = 1, #(src.checks or {}) do
    local x = src.checks[i]
    local id = x.id or tostring(x)
    if not seen_c[id] then
      seen_c[id] = true
      dst.checks[#dst.checks + 1] = x
    end
  end
  for i = 1, #(src.activation_keys or {}) do
    local key = src.activation_keys[i]
    if not seen_a[key] then
      seen_a[key] = true
      dst.activation_keys[#dst.activation_keys + 1] = key
    end
  end
  return dst
end

local function refutation_activation_label(refutation)
  local keys = {}
  for i = 1, #((refutation and refutation.activation_keys) or {}) do
    keys[i] = refutation.activation_keys[i]
  end
  table.sort(keys)
  return #keys > 0 and table.concat(keys, '|') or '-'
end

local function terminal_refutation(state)
  local out = { interests = {}, checks = {}, activation_keys = {} }
  for i = 1, #state.intents do
    local intent = state.intents[i]
    if intent.interest then
      out.interests[#out.interests + 1] = intent.interest
    end
    if intent.absence_check then
      local check = intent.absence_check
      if type(check) == 'function' then
        check = { validate = check, id = 'absence:' .. tostring(intent.id) }
      end
      out.checks[#out.checks + 1] = check
    elseif intent.program and intent.program.location then
      local loc = intent.program.location
      local observed_version = intent.program.observed_version or loc.version
      out.checks[#out.checks + 1] = {
        id = 'location:' .. tostring(loc.id) .. ':' .. tostring(observed_version),
        validate = function()
          return loc.version == observed_version
        end,
      }
    end
  end
  local facts = {}
  for i = 1, #out.interests do
    local interest = out.interests[i]
    facts[#facts + 1] = 'i:' .. tostring(interest.id or interest)
  end
  for i = 1, #out.checks do
    local check = out.checks[i]
    facts[#facts + 1] = 'c:' .. tostring(check.id or check)
  end
  table.sort(facts)
  out.activation_keys[1] = #facts > 0 and table.concat(facts, ',') or '-'
  return out
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

local function memo_enter(state, node)
  if
    state.state_memoization_possible
    and search_work_steps(state) >= (state.state_memoization_min_steps or 0)
    and #(state.intents or {}) >= (state.state_memoization_min_intents or 0)
  then
    local cache = search_cache(state)
    local signature = SearchCache.probe_state(cache, state)
    local cached = signature and SearchCache.get_state(cache, signature)
    if cached then
      return cached
    end
    node.memo_signature = signature
  end
  return nil
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

-- Drain deterministic task work until the evaluator reaches a blocked frontier
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
          return 'retry', terminal_refutation(state)
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
        setv(state, task, 'activation', Activation.child(parent_activation, 'and_then:prefix'))
        add_active(state, task.id)
      elseif kind == 'annotated' then
        local parent_activation = task.activation
        if expr.post then
          pushv(state, task.frames, { kind = 'wrap', fn = expr.post })
        end
        if expr.symmetry_key ~= nil then
          pushv(
            state,
            task.frames,
            { kind = 'symmetry_restore', previous_symmetry = task.symmetry_key }
          )
          setv(state, task, 'symmetry_key', expr.symmetry_key)
        end
        setv(state, task, 'expr', expr.p)
        setv(state, task, 'activation', Activation.child(parent_activation, 'annotated:body'))
        add_active(state, task.id)
      elseif kind == 'consequence' then
        pushv(state, state.effects, expr.effect)
        if not complete_task(state, task, new_outcome(state, pack_(), nil, task)) then
          return 'retry', terminal_refutation(state)
        end
      elseif kind == 'primitive' then
        if not execute_program(state, task, expr.program, expr) then
          return 'retry', terminal_refutation(state)
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
            refutation = nil,
          }
      elseif kind == 'or_else' then
        return 'branch',
          {
            kind = 'or_else',
            task_id = task.id,
            expr = expr,
            activation = task.activation,
            phase = 'preferred',
            refutation = nil,
            preferred_refutation = nil,
          }
      else
        error('unsupported Op kind: ' .. tostring(kind), 0)
      end
    end
  end
  return 'blocked'
end

local function analyse_frontier(state)
  local profile_plan = state.profile_plan
  if profile_plan and state.runtime.instrumentation.state_hash then
    state.runtime.instrumentation:observe_state(
      profile_plan,
      SearchCache.signature(state, false),
      false
    )
  end
  local frontier = Frontier.analyse(
    state,
    intents_compatible,
    state.runtime.branch_policy ~= 'legacy',
    state.session:frontier_scratch()
  )
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
    profile_plan.claim_groups_scanned = profile_plan.claim_groups_scanned + #frontier.claims
    for i = 1, #frontier.claims do
      local size = #frontier.claims[i].ids
      if size > profile_plan.max_claim_group then
        profile_plan.max_claim_group = size
      end
    end
  end
  return frontier
end

-- Apply only the two reductions already certified by the previous machine.
-- The return value is true for progress, false plus a refutation for a failed
-- forced action, and nil when genuine branching remains.
local function raw_exchange_program(op)
  if not op or op.kind ~= 'primitive' then
    return nil
  end
  local program = op.program
  if
    not program
    or programme_kind(program) ~= 'exchange'
    or not (program._fibers_compact_descriptor or program == op)
  then
    return nil
  end
  return program
end

local function recruit_forced_raw_exchange(state, exchange)
  if
    #state.intents ~= 1
    or #exchange.pairs ~= 0
    or state.session.stack ~= nil
  then
    return false
  end
  local intent = state.intents[1]
  local task = intent and state.tasks[intent.task_id]
  local current = task and #task.frames == 0 and raw_exchange_program(task.expr) or nil
  if not current or current ~= intent.program then
    return false
  end
  local rows = supplier_rows(state)
  if #rows ~= 1 then
    return false
  end
  local row = rows[1]
  local request = state.requests[row.id]
  local supplier = raw_exchange_program(request and request.op)
  if
    not supplier
    or supplier.resource ~= current.resource
    or supplier.role == current.role
  then
    return false
  end
  add_root(state, row.id)
  local profile_plan = state.profile_plan
  if profile_plan then
    profile_plan.forced_recruitments = (profile_plan.forced_recruitments or 0) + 1
    profile_plan.normalisation_rounds = profile_plan.normalisation_rounds + 1
  end
  return true
end

local function apply_forced_frontier(state, frontier)
  if state.runtime.normalise_search == false then
    return nil
  end
  local profile_plan = state.profile_plan
  local exchange = frontier.exchange
  if recruit_forced_raw_exchange(state, exchange) then
    return true
  end
  if #state.intents == 2 and exchange.selected_degree == 1 and #exchange.pairs == 1 then
    if not has_supplier(state, { exchange.selected }) then
      if profile_plan then
        profile_plan.forced_exchange_opportunities = profile_plan.forced_exchange_opportunities + 1
        profile_plan.forced_exchanges = profile_plan.forced_exchanges + 1
        profile_plan.normalisation_rounds = profile_plan.normalisation_rounds + 1
      end
      local pair = exchange.pairs[1]
      if match_intents(state, pair.left, pair.right) then
        return true
      end
      local terminal = terminal_refutation(state)
      if profile_plan and state.runtime.instrumentation.state_hash then
        state.runtime.instrumentation:observe_state(
          profile_plan,
          SearchCache.signature(state, true),
          true
        )
      end
      return false, terminal
    end
  end

  local groups = frontier.claims
  if #groups == 1 then
    local group = groups[1]
    if group.all_machine and group.supply_none and #group.ids == #state.intents then
      if not has_supplier(state, group.intents) then
        if profile_plan then
          profile_plan.forced_claim_opportunities = profile_plan.forced_claim_opportunities + 1
          profile_plan.forced_claims = profile_plan.forced_claims + 1
          profile_plan.normalisation_rounds = profile_plan.normalisation_rounds + 1
        end
        if resolve_claim_set(state, group, group.ids) then
          return true
        end
        return false, terminal_refutation(state)
      end
    end
  end
  return nil
end

local function new_frontier_frame(frontier)
  frontier = Frontier.detach(frontier)
  return {
    kind = 'frontier',
    frontier = frontier,
    phase = 'exchange',
    pair_index = 1,
    witness_index = 1,
    witness_cursor = nil,
    claim_index = 1,
    claim_phase = nil,
    claim_single_index = 1,
    supplier_ready = false,
    supplier_row = nil,
    supplier_phase = 1,
    refutation = nil,
  }
end

local function observe_supplier_rows(state, frame)
  if frame.supplier_ready then
    return
  end
  frame.supplier_ready = true
  local frontier = frame.frontier
  local suppliers, supplier_refutation_hit = {}, false
  if frontier.accepts_participant_supply then
    suppliers, supplier_refutation_hit = supplier_rows(state)
  end
  local profile_plan = state.profile_plan
  if profile_plan then
    if not supplier_refutation_hit then
      profile_plan.footprint_checks = profile_plan.footprint_checks
        + math.max(0, map_count(state.requests) - map_count(state.roots))
    end
    profile_plan.recruitment_candidates = profile_plan.recruitment_candidates + #suppliers
    if suppliers[1] then
      profile_plan.recruitment_best_score =
        math.max(profile_plan.recruitment_best_score or 0, suppliers[1].score or 0)
      profile_plan.footprint_matches = profile_plan.footprint_matches + #suppliers
      local key = 'footprint_' .. tostring(suppliers[1].reason or 'unknown') .. '_matches'
      profile_plan[key] = (profile_plan[key] or 0) + 1
    end
  end
  frame.supplier_row = suppliers[1]
end

local function next_frontier_alternative(state, frame)
  local frontier = frame.frontier
  while true do
    if frame.phase == 'exchange' then
      local pair = frontier.exchange.pairs[frame.pair_index]
      if pair then
        frame.pair_index = frame.pair_index + 1
        return { kind = 'exchange', pair = pair, domain = frontier.exchange.selected_degree }
      end
      frame.phase = 'witness'
    elseif frame.phase == 'witness' then
      local intent = frontier.witnesses[frame.witness_index]
      if not intent then
        frame.phase = 'claim'
      else
        if not frame.witness_cursor then
          frame.witness_cursor = witness_cursor(state, intent)
        end
        local alt = frame.witness_cursor:next()
        if alt ~= nil then
          frame.witness_alternative_index = (frame.witness_alternative_index or 0) + 1
          return {
            kind = 'witness',
            intent_id = intent.id,
            alternative = alt,
            alternative_index = frame.witness_alternative_index,
          }
        end
        frame.witness_alternative_index = 0
        frame.witness_cursor = nil
        frame.witness_index = frame.witness_index + 1
      end
    elseif frame.phase == 'claim' then
      local group = frontier.claims[frame.claim_index]
      if not group then
        frame.phase = 'supplier'
      else
        if frame.claim_phase == nil then
          if group.all_machine and group.supply_none then
            frame.claim_phase = 'all_only'
          elseif group.all_machine and #group.ids > 1 then
            frame.claim_phase = 'whole'
          else
            frame.claim_phase = 'singles'
          end
          frame.claim_single_index = 1
        end

        if frame.claim_phase == 'all_only' then
          frame.claim_phase = 'done'
          return { kind = 'claim', group = group, ids = group.ids, claim_kind = 'all' }
        elseif frame.claim_phase == 'whole' then
          frame.claim_phase = 'singles'
          return { kind = 'claim', group = group, ids = group.ids, claim_kind = 'all' }
        elseif frame.claim_phase == 'singles' then
          local id = group.ids[frame.claim_single_index]
          if id then
            frame.claim_single_index = frame.claim_single_index + 1
            return { kind = 'claim', group = group, ids = { id }, claim_kind = 'single' }
          end
          frame.claim_phase = 'done'
        end

        if frame.claim_phase == 'done' then
          frame.claim_index = frame.claim_index + 1
          frame.claim_phase = nil
        end
      end
    elseif frame.phase == 'supplier' then
      observe_supplier_rows(state, frame)
      local row = frame.supplier_row
      if not row then
        frame.phase = 'done'
      elseif frame.supplier_phase == 1 then
        frame.supplier_phase = 2
        return { kind = 'recruit', row = row }
      elseif frame.supplier_phase == 2 then
        frame.supplier_phase = 3
        return { kind = 'exclude', row = row }
      else
        frame.phase = 'done'
      end
    else
      return nil
    end
  end
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
  elseif frame.kind == 'frontier' then
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
    setv(
      state,
      task,
      'activation',
      Activation.child(frame.activation, 'choice:' .. tostring(alt.choice_index))
    )
    add_active(state, task.id)
    return true
  elseif alt.kind == 'or_else_preferred' then
    if profile_plan then
      profile_plan.preferred_branches = profile_plan.preferred_branches + 1
      state.runtime.instrumentation:event(profile_plan, 'or_else_preferred')
    end
    local task = state.tasks[frame.task_id]
    setv(state, task, 'expr', frame.expr.p)
    setv(state, task, 'activation', Activation.child(frame.activation, 'or_else:preferred'))
    add_active(state, task.id)
    return true
  elseif alt.kind == 'or_else_fallback' then
    if profile_plan then
      profile_plan.fallback_branches = profile_plan.fallback_branches + 1
      state.runtime.instrumentation:event(profile_plan, 'or_else_fallback')
    end
    setv(state, state, 'used_fallback', true)
    local pref = frame.preferred_refutation
    for i = 1, #((pref and pref.checks) or {}) do
      pushv(state, state.negative_checks, pref.checks[i])
    end
    for i = 1, #((pref and pref.interests) or {}) do
      pushv(state, state.fallback_interests, pref.interests[i])
    end
    local task = state.tasks[frame.task_id]
    setv(state, task, 'expr', frame.expr.q)
    setv(
      state,
      task,
      'activation',
      Activation.child(
        frame.activation,
        'or_else:fallback:' .. refutation_activation_label(pref)
      )
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
  elseif alt.kind == 'claim' then
    if profile_plan then
      profile_plan.claim_branches = profile_plan.claim_branches + 1
      if alt.claim_kind == 'all' then
        profile_plan.claim_all_branches = profile_plan.claim_all_branches + 1
      else
        profile_plan.claim_single_branches = profile_plan.claim_single_branches + 1
      end
    end
    return resolve_claim_set(state, alt.group, alt.ids)
  elseif alt.kind == 'recruit' then
    local row = alt.row
    if profile_plan then
      profile_plan.recruit_branches = profile_plan.recruit_branches + 1
      state.runtime.instrumentation:event(
        profile_plan,
        'recruit_root',
        { root = row.id, score = row.score }
      )
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

local function branch_child_result(state, frame, outcome, candidate, refutation)
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
    frame.refutation = merge_refutation(frame.refutation, refutation)
    return 'continue'
  elseif frame.kind == 'or_else' then
    if outcome == 'hit' then
      return 'done', 'hit', candidate, nil
    end
    if frame.phase == 'preferred_running' then
      frame.preferred_refutation = refutation
      frame.phase = 'fallback'
      return 'continue'
    end
    return 'done', 'retry', nil, refutation or { interests = {}, checks = {} }
  elseif frame.kind == 'frontier' then
    if outcome == 'hit' then
      return 'done', 'hit', candidate, nil
    end
    frame.refutation = merge_refutation(frame.refutation, refutation)
    return 'continue'
  end
  error('unknown branch result frame: ' .. tostring(frame.kind), 0)
end

local function exhausted_branch_result(state, frame)
  if frame.kind == 'choice' then
    return frame.refutation or terminal_refutation(state)
  elseif frame.kind == 'or_else' then
    -- Both phases normally complete directly from branch_child_result.  This
    -- fallback protects malformed frames without changing user-visible facts.
    return frame.preferred_refutation or { interests = {}, checks = {} }
  elseif frame.kind == 'frontier' then
    if state.profile_plan and state.runtime.instrumentation.state_hash then
      state.runtime.instrumentation:observe_state(
        state.profile_plan,
        SearchCache.signature(state, true),
        true
      )
    end
    return merge_refutation(frame.refutation, terminal_refutation(state))
  end
  error('unknown exhausted branch frame: ' .. tostring(frame.kind), 0)
end

local function finish_node(session, outcome, candidate, refutation)
  local state, stack = session.state, session.stack
  while true do
    if not stack then
      if outcome == 'retry' and session.memo_signature then
        SearchCache.put_state(search_cache(state), session.memo_signature, refutation)
      end
      session.result_kind = outcome
      session.result_candidate = candidate
      session.result_refutation = refutation
      return true
    end

    local node = stack[#stack]
    if not node or node.kind ~= 'node' then
      error('search stack lost its node frame', 0)
    end
    stack[#stack] = nil
    if outcome == 'retry' and node.memo_signature then
      SearchCache.put_state(search_cache(state), node.memo_signature, refutation)
    end

    local branch = stack[#stack]
    if not branch then
      session.stack = nil
      session.result_kind = outcome
      session.result_candidate = candidate
      session.result_refutation = refutation
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

    local action, next_outcome, next_candidate, next_refutation =
      branch_child_result(state, branch, outcome, candidate, refutation)
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
    outcome, candidate, refutation = next_outcome, next_candidate, next_refutation
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
    stack[1] = { kind = 'node', phase = 'waiting', memo_signature = session.memo_signature }
    stack[2] = branch
    session.stack = stack
    session.phase, session.memo_signature = nil, nil
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
      return session.result_candidate, session.result_refutation, false
    end

    local stack = session.stack
    local frame = stack and stack[#stack] or session
    local is_node = not stack or frame.kind == 'node'

    if not is_node then
      if frame.waiting then
        error('waiting branch has no child node', 0)
      end
      if start_branch_alternative(session, frame) and session.result_kind then
        return session.result_candidate, session.result_refutation, false
      end
    elseif frame.phase == 'enter' then
      local cached = memo_enter(state, frame)
      if cached then
        if finish_node(session, 'retry', nil, cached) and session.result_kind then
          return session.result_candidate, session.result_refutation, false
        end
      else
        frame.phase = 'reduce'
      end
    elseif frame.phase == 'reduce' then
      if not begin_search_round(state) then
        return nil, { interests = {}, checks = {} }, true
      end

      local action, payload = drain_active(state)
      if action == 'retry' then
        if finish_node(session, 'retry', nil, payload) and session.result_kind then
          return session.result_candidate, session.result_refutation, false
        end
      elseif action == 'branch' then
        push_branch(session, payload)
      else
        local candidate = final_candidate(state)
        if candidate then
          if finish_node(session, 'hit', candidate, nil) and session.result_kind then
            return session.result_candidate, session.result_refutation, false
          end
        else
          local frontier = analyse_frontier(state)
          local progressed, forced_refutation = apply_forced_frontier(state, frontier)
          if progressed == true then
            -- Continue the fixed point in the inline or stacked node.
          elseif progressed == false then
            if finish_node(session, 'retry', nil, forced_refutation) and session.result_kind then
              return session.result_candidate, session.result_refutation, false
            end
          else
            push_branch(session, new_frontier_frame(frontier))
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
  if not state.trail then
    state.trail = Trail.new(runtime.stats, session.profile_plan)
  else
    state.trail:begin(runtime.stats, session.profile_plan)
  end
  add_root(state, focus_id)
  return session
end

function M.search(runtime, requests, focus_id, search_limit, component)
  local session = M.new_session(runtime, requests, focus_id, component)
  if not session then
    return nil
  end
  local candidate, refutation, unknown = session:advance(search_limit or runtime.search_limit)
  return candidate, refutation, unknown, session
end

return M

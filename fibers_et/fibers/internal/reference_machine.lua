-- Copy-on-branch semantic reference evaluator.
-- Kept outside the active kernel for differential testing.

local Op = require('fibers.atoms.op')
local Store = require('fibers.kernel.store')
local IR = require('fibers.kernel.ir')
local ChoiceOrder = require('fibers.kernel.choice_order')
local Frontier = require('fibers.kernel.frontier')
local SearchCache = require('fibers.kernel.adaptive_search')

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

local function copy_array(xs)
  local out = {}
  for i = 1, #(xs or {}) do
    out[i] = xs[i]
  end
  return out
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
    views = {},
    intents = {},
    intent_by_id = {},
    effects = copy_array(s.effects),
    used_fallback = s.used_fallback,
    negative_checks = copy_array(s.negative_checks),
    fallback_interests = copy_array(s.fallback_interests),
    excluded_roots = copy_map(s.excluded_roots),
    next_task = s.next_task,
    next_group = s.next_group,
    next_view = s.next_view,
    next_intent = s.next_intent,
    next_machine_serial = s.next_machine_serial,
    search_steps = s.search_steps,
    search_work = s.search_work,
    search_limit = s.search_limit,
    profile_plan = s.profile_plan,
    state_memoization_possible = s.state_memoization_possible,
    state_memoization_min_steps = s.state_memoization_min_steps,
    refutation_cache_possible = s.refutation_cache_possible,
    refutation_cache_min_steps = s.refutation_cache_min_steps,
    component = s.component,
    plan_id = s.plan_id,
  }

  for id, t in pairs(s.tasks) do
    out.tasks[id] = {
      id = t.id,
      root_id = t.root_id,
      expr = t.expr,
      frames = copy_frames(t.frames),
      view_id = t.view_id,
      scope_path = copy_scope_path(t.scope_path),
      status = t.status,
      choice_serial = t.choice_serial,
      symmetry_key = t.symmetry_key,
    }
  end

  for id, r in pairs(s.roots) do
    out.roots[id] = {
      request = r.request,
      view_id = r.view_id,
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
      parent_view = g.parent_view,
      mode = g.mode,
      count = g.count,
      lane_views = copy_array(g.lane_views),
      lane_outcomes = lane_outcomes,
      completed = g.completed,
    }
  end

  for id, v in pairs(s.views) do
    local cloned = Store.clone_view(v)
    cloned.scope_path = copy_scope_path(v.scope_path)
    out.views[id] = cloned
  end
  for id, v in pairs(s.views) do
    if v.parent then
      out.views[id].parent = out.views[v.parent.id]
    end
  end

  for i = 1, #s.intents do
    out.intents[i] = Store.copy_intent(s.intents[i])
  end
  rebuild_intent_indexes(out)
  return out
end

local function new_view(state, root_id, scope_path, source_view_id)
  state.next_view = state.next_view + 1
  local id = state.next_view
  local source = source_view_id and state.views[source_view_id] or nil
  state.views[id] = Store.new_view(root_id, copy_scope_path(scope_path), source, id)
  return id
end

local function merge_group_views(state, group)
  local parent = state.views[group.parent_view]
  local children = {}
  for i = 1, group.count do
    children[i] = state.views[group.lane_views[i]]
  end
  return Store.merge_views(parent, children, group.mode)
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
  parent.status = 'active'
  return complete_task(state, parent, {
    pack = pack_(rows),
    wrap = product_wrap(group.lane_outcomes),
  })
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
      local request = state.roots[task.root_id].request
      if frame.phase == 'guard' then
        local cached = request.memo[frame.cache_key]
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
          request.memo[frame.cache_key] = cached
        end
        task.expr = cached
      elseif frame.phase == 'map' then
        task.expr = Op.always(
          state.runtime:_call_in_phase('map', 'callback_error', frame.fn, unpack_pack(outcome.pack))
        )
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
        task.expr = next_op
      end
      add_active(state, task.id)
      return true
    elseif frame.kind == 'wrap' then
      outcome = { pack = outcome.pack, wrap = compose_wrap(outcome.wrap, frame.fn) }
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

  local view_id = new_view(state, root_id, {})
  state.next_task = state.next_task + 1
  local task_id = state.next_task
  state.tasks[task_id] = {
    id = task_id,
    root_id = root_id,
    expr = request.op,
    frames = {},
    view_id = view_id,
    scope_path = {},
    status = 'active',
    choice_serial = 0,
    symmetry_key = nil,
  }
  state.roots[root_id] = {
    request = request,
    view_id = view_id,
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
    parent_view = task.view_id,
    mode = op.mode,
    count = #op.lanes,
    lane_views = {},
    lane_outcomes = {},
    completed = 0,
  }
  state.groups[group_id] = group
  task.status = 'waiting_group'

  for i = 1, #op.lanes do
    local path = copy_scope_path(task.scope_path)
    path[#path + 1] = { group_id = group_id, mode = op.mode, lane = i }
    local view_id = new_view(state, task.root_id, path, task.view_id)
    group.lane_views[i] = view_id
    state.next_task = state.next_task + 1
    local child_id = state.next_task
    state.tasks[child_id] = {
      id = child_id,
      root_id = task.root_id,
      expr = op.lanes[i],
      frames = { { kind = 'group_lane', group_id = group_id, lane = i } },
      view_id = view_id,
      scope_path = path,
      status = 'active',
      choice_serial = 0,
      symmetry_key = task.symmetry_key,
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

local function remove_two(xs, i, j)
  if i > j then
    i, j = j, i
  end
  table.remove(xs, j)
  table.remove(xs, i)
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
  local kind = program.result_kind or 'constant'
  if kind == 'constant' then
    return pack_(program.result_value)
  end
  if kind == 'identity' then
    return pack_(value)
  end
  if kind == 'presence_bool' then
    return pack_(value ~= Store.ABSENT)
  end
  if kind == 'presence_value' then
    if value == Store.ABSENT then
      return pack_(nil)
    end
    if program.nil_sentinel and value == program.nil_sentinel then
      return pack_(nil)
    end
    return pack_(value)
  end
  if kind == 'index_entry' then
    if value == nil then
      return pack_(nil)
    end
    return pack_({ key = value.key, rank = value.rank, value = value.value, seq = value.seq })
  end
  if kind == 'map_value' then
    return pack_(value)
  end
  if kind == 'scalar_snapshot' then
    return pack_({ value = value, version = program.location.version })
  end
  if kind == 'counter_state' then
    local owner = program.owner
    return pack_({
      value = value,
      min = owner.min,
      max = owner.max,
      version = program.location.version,
    })
  end
  error('unknown programme result kind: ' .. tostring(kind), 0)
end

local function predicate_holds(program, value)
  if program.predicate == 'present' then
    return value ~= Store.ABSENT
  end
  if program.predicate == 'absent' then
    return value == Store.ABSENT
  end
  if program.predicate == 'ge' then
    return value >= program.threshold
  end
  if program.predicate == 'map_present' then
    return value[program.key] ~= nil
  end
  if program.predicate == 'map_absent' then
    return value[program.key] == nil
  end
  error('unknown claim predicate: ' .. tostring(program.predicate), 0)
end

local function select_extreme(program, value)
  local candidates = {}
  for key, entry in pairs(value or {}) do
    candidates[#candidates + 1] = { key = key, entry = entry }
  end
  table.sort(candidates, function(a, b)
    local ae, be = a.entry, b.entry
    local ar = ae[program.rank_field or 'rank']
    local br = be[program.rank_field or 'rank']
    if ar == br then
      local as = ae[program.seq_field or 'seq'] or 0
      local bs = be[program.seq_field or 'seq'] or 0
      if as == bs then
        return tostring(a.key) < tostring(b.key)
      end
      return as < bs
    end
    return ar < br
  end)
  if #candidates == 0 then
    return nil
  end
  if program.order == 'max' then
    return candidates[#candidates]
  end
  return candidates[1]
end

local function modes_compatible(compat, a, b)
  if a == b then
    return true
  end
  local row = compat and compat[a]
  return row and row[b] == true
end

local function evaluate_claim(program, value)
  local query = program.query
  if not query and kind == 'conditional_claim' then
    query = {
      kind = 'predicate',
      predicate = program.predicate,
      threshold = program.threshold,
      key = program.key,
    }
  end
  if not query then
    error('claim programme is missing query', 0)
  end

  local witness = value
  if query.kind == 'predicate' then
    local probe = {
      predicate = query.predicate,
      threshold = query.threshold,
      key = query.key,
    }
    if not predicate_holds(probe, value) then
      return nil
    end
  elseif query.kind == 'extreme' then
    local selected = select_extreme(query, value)
    if not selected then
      return nil
    end
    witness = selected
  elseif query.kind == 'compatible_insert' then
    for owner, mode in pairs(value or {}) do
      if
        owner ~= query.key
        and not (
          modes_compatible(query.compatibility, query.value, mode)
          and modes_compatible(query.compatibility, mode, query.value)
        )
      then
        return nil
      end
    end
  else
    error('unknown claim query: ' .. tostring(query.kind), 0)
  end

  local transition = program.transition
  if not transition and kind == 'conditional_claim' then
    transition = { kind = 'static', patch = program.claim_patch }
  end

  local patch = nil
  if transition then
    if transition.kind == 'static' then
      patch = transition.patch
    elseif transition.kind == 'take_witness' then
      patch = { kind = 'finite_map', ops = { { op = 'take', key = witness.key } } }
    elseif transition.kind == 'put' then
      patch = {
        kind = 'finite_map',
        ops = {
          {
            op = 'put',
            key = transition.key,
            value = transition.value,
            policy = transition.policy,
          },
        },
      }
    else
      error('unknown claim transition: ' .. tostring(transition.kind), 0)
    end
  end

  local result_value = witness
  if query.kind == 'extreme' then
    result_value = witness.entry
  end
  return {
    patch = patch,
    result = result_pack(program, result_value),
  }
end

local function block_intent(state, task, program, occurrence)
  state.next_intent = state.next_intent + 1
  task.status = 'blocked'
  local intent = {
    id = state.next_intent,
    kind = programme_kind(program),
    task_id = task.id,
    root_id = task.root_id,
    program = program,
    resource = program.resource or program.group,
    role = program.role,
    value = program.payload_field == 'value' and occurrence.payload or program.value,
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
  if not complete_task(state, put_task, { pack = PACK_TRUE }) then
    return false
  end
  if not complete_task(state, get_task, { pack = pack_(put.value) }) then
    return false
  end
  return true
end

local function is_machine_wait(x)
  return x == require('fibers.atoms.scalar').Wait
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
  local t, payload = program.transition, program.payload or {}
  if type(t.ready) == 'function' then
    local out = t.ready(value, payload, machine_context(state))
    return out ~= nil and out ~= false and not is_machine_wait(out)
  end
  local packed = pack_(t.step(value, payload, machine_context(state)))
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
  local t, payload = program.transition, program.payload or {}
  local packed = pack_(t.step(value, payload, machine_context(state)))
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
      result = first.pack or pack_(),
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
  local resolved = {}
  for i = 1, #selected do
    local intent = selected[i]
    local program = intent.program
    local task = state.tasks[intent.task_id]
    local value = Store.project_machine(state, task, program.location, function(v)
      return machine_probe(state, program, v)
    end, program.transition.supply)
    local r = run_machine_transition(state, program, value)
    if not r then
      return false
    end
    if r.writes then
      state.next_machine_serial = state.next_machine_serial + 1
      Store.stage(state.views[task.view_id], program.location, {
        kind = 'machine',
        steps = { { serial = state.next_machine_serial, value = r.value } },
      })
    else
      -- Ensure the location version is part of the observation set.
      Store.cell(state.views[task.view_id], program.location)
    end
    resolved[#resolved + 1] = { intent = intent, task = task, result = r.result }
  end
  local ids = {}
  for i = 1, #selected do
    ids[i] = selected[i].id
  end
  remove_intent_ids(state, ids)
  for i = 1, #resolved do
    if not complete_task(state, resolved[i].task, { pack = resolved[i].result }) then
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

  local resolved = {}
  for i = 1, #selected do
    local intent = selected[i]
    local program = intent.program
    local loc = program.location
    local task = state.tasks[intent.task_id]
    local value = Store.project(state, task, loc, program.orientation or program.demand_tag)
    if value == nil then
      return false
    end
    local resolution = evaluate_claim(program, value)
    if not resolution then
      return false
    end

    -- Stage immediately, but do not complete the task yet. Later claims see
    -- the mutation through the ordinary provenance rules.
    if resolution.patch then
      Store.stage(state.views[task.view_id], loc, resolution.patch)
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
    if not complete_task(state, r.task, { pack = r.result }) then
      return false
    end
  end
  return true
end

local function witness_cursor(state, intent)
  local program = intent.program
  local task = state.tasks[intent.task_id]
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

local function resolve_witness(state, intent_id, alt)
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
  local packed = alt.result
  if not (type(packed) == 'table' and packed._fibers_pack == true) then
    if type(packed) == 'table' and packed.n ~= nil then
      packed._fibers_pack = true
    else
      packed = pack_(packed)
    end
  end
  return complete_task(state, task, { pack = packed })
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
  for _, root in pairs(state.roots) do
    if not root.done then
      return nil
    end
  end
  if #state.intents > 0 then
    return nil
  end

  local root_views = {}
  for _, root in pairs(state.roots) do
    root_views[#root_views + 1] = state.views[root.view_id]
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

  local participants, outcomes = {}, {}
  for id, root in pairs(state.roots) do
    participants[#participants + 1] = id
    outcomes[id] = root.outcome
  end
  table.sort(participants)

  local candidate = {
    focus = state.focus,
    participants = participants,
    outcomes = outcomes,
    observations = observations,
    writes = writes,
    effects = #state.effects > 0 and copy_array(state.effects) or nil,
    negative_guard = state.used_fallback == true,
    epoch = state.runtime.epoch,
    pending_generation = state.runtime.pending_generation,
    negative_checks = #state.negative_checks > 0 and copy_array(state.negative_checks) or nil,
    fallback_interests = #state.fallback_interests > 0 and copy_array(state.fallback_interests)
      or nil,
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
    local view = state.views[task.view_id]
    if program.snapshot_kind == 'keyed' then
      local entries, keys = {}, {}
      for k in pairs(resource.entries) do
        keys[k] = true
      end
      for k in pairs(resource._locations) do
        keys[k] = true
      end
      for k in pairs(keys) do
        local value = Store.read(view, resource:_location(k))
        if value ~= Store.ABSENT then
          if resource._nil_sentinel and value == resource._nil_sentinel then
            entries[k] = nil
          else
            entries[k] = value
          end
        end
      end
      return complete_task(
        state,
        task,
        { pack = pack_({ entries = entries, version = resource.version }) }
      )
    elseif program.snapshot_kind == 'index' then
      local value = Store.read(view, resource._location)
      local entries = {}
      for k, e in pairs(value or {}) do
        entries[k] = { key = e.key, rank = e.rank, value = e.value, seq = e.seq }
      end
      return complete_task(
        state,
        task,
        { pack = pack_({ entries = entries, version = resource.version }) }
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
        local hs = Store.read(view, loc)
        holders[subject] = {}
        for owner, mode in pairs(hs or {}) do
          holders[subject][owner] = mode
        end
      end
      return complete_task(
        state,
        task,
        { pack = pack_({ holders = holders, version = resource.version }) }
      )
    end
    error('unknown snapshot kind', 0)
  end

  local view = state.views[task.view_id]
  local loc = program.location

  if kind == 'version_wait' then
    if loc.version ~= program.version then
      Store.cell(view, loc)
      return complete_task(state, task, { pack = pack_(Store.read(view, loc), loc.version) })
    end
    program.observed_version = loc.version
    block_intent(state, task, program)
    return true
  end

  if kind == 'read' then
    return complete_task(state, task, { pack = result_pack(program, Store.read(view, loc)) })
  end

  if kind == 'patch' then
    local patch = program.patch
    if program.payload_patch == 'replace' then
      patch = { kind = 'replace', value = occurrence.payload }
    end
    Store.stage(view, loc, patch)
    return complete_task(state, task, { pack = result_pack(program, Store.read(view, loc)) })
  end

  if kind == 'claim' or kind == 'machine_transition' or kind == 'witness_transition' then
    block_intent(state, task, program)
    return true
  end

  if kind == 'conditional_claim' then
    local value = Store.read(view, loc)
    if predicate_holds(program, value) then
      Store.stage(view, loc, program.immediate_patch)
      return complete_task(state, task, { pack = result_pack(program, value) })
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
  dst = dst or { interests = {}, checks = {} }
  local seen_i, seen_c = {}, {}
  for i = 1, #dst.interests do
    seen_i[dst.interests[i].id or tostring(dst.interests[i])] = true
  end
  for i = 1, #dst.checks do
    seen_c[dst.checks[i].id or tostring(dst.checks[i])] = true
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
  return dst
end

local function terminal_refutation(state)
  local out = { interests = {}, checks = {} }
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

local function request_may_supply(request, intents)
  local metadata = request.metadata or request.footprint or IR.metadata(request.op)
  request.metadata, request.footprint = metadata, metadata
  return IR.footprint_may_supply(metadata, intents)
end

local dfs, dfs_impl

dfs = function(state)
  local signature
  if
    state.state_memoization_possible
    and search_work_steps(state) >= (state.state_memoization_min_steps or 0)
    and #(state.intents or {}) >= (state.state_memoization_min_intents or 0)
  then
    local cache = search_cache(state)
    signature = SearchCache.probe_state(cache, state)
    local cached = signature and SearchCache.get_state(cache, signature)
    if cached then
      return nil, cached, false
    end
  end
  local found, refutation, unknown = dfs_impl(state)
  if signature and not found and not unknown then
    SearchCache.put_state(search_cache(state), signature, refutation)
  end
  return found, refutation, unknown
end

dfs_impl = function(state)
  state.runtime.stats.search_calls = state.runtime.stats.search_calls + 1
  local profile_plan = state.profile_plan
  if profile_plan then
    profile_plan.search_calls = profile_plan.search_calls + 1
  end
  state.search_work.steps = state.search_work.steps + 1
  state.search_steps = state.search_work.steps
  if state.search_steps > state.search_limit then
    return nil, { interests = {}, checks = {} }, true
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
          if not complete_task(state, task, { pack = expr.vals }) then
            return nil, terminal_refutation(state), false
          end
        elseif kind == 'and_then' then
          task.frames[#task.frames + 1] = {
            kind = 'bind',
            fn = expr.fn,
            phase = expr.callback_phase,
            cache_key = expr.cache_key,
            continuation_footprint = expr.continuation_footprint,
          }
          task.expr = expr.p
          add_active(state, task.id)
        elseif kind == 'annotated' then
          if expr.post then
            task.frames[#task.frames + 1] = { kind = 'wrap', fn = expr.post }
          end
          if expr.symmetry_key ~= nil then
            task.frames[#task.frames + 1] =
              { kind = 'symmetry_restore', previous_symmetry = task.symmetry_key }
            task.symmetry_key = expr.symmetry_key
          end
          task.expr = expr.p
          add_active(state, task.id)
        elseif kind == 'consequence' then
          state.effects[#state.effects + 1] = expr.effect
          if not complete_task(state, task, { pack = pack_() }) then
            return nil, terminal_refutation(state), false
          end
        elseif kind == 'primitive' then
          if not execute_program(state, task, expr.program, expr) then
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
            refutation = merge_refutation(refutation, ref)
            if unknown then
              return nil, refutation, true
            end
          end
          return nil, refutation or terminal_refutation(state), false
        elseif kind == 'or_else' then
          local primary = clone_state(state)
          local pt = primary.tasks[task.id]
          pt.expr = expr.p
          add_active(primary, pt.id)
          local found, pref, unknown = dfs(primary)
          if found then
            return found
          end
          if unknown then
            return nil, pref, true
          end

          local fallback = clone_state(state)
          fallback.used_fallback = true
          for i = 1, #((pref and pref.checks) or {}) do
            fallback.negative_checks[#fallback.negative_checks + 1] = pref.checks[i]
          end
          for i = 1, #((pref and pref.interests) or {}) do
            fallback.fallback_interests[#fallback.fallback_interests + 1] = pref.interests[i]
          end
          local ft = fallback.tasks[task.id]
          ft.expr = expr.q
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
          return nil, fref or { interests = {}, checks = {} }, funknown
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

      local frontier =
        Frontier.analyse(state, intents_compatible, state.runtime.branch_policy ~= 'legacy')
      local exchange = frontier.exchange
      if profile_plan then
        profile_plan.intent_pairs_scanned = profile_plan.intent_pairs_scanned + exchange.scans
        profile_plan.compatible_pairs = profile_plan.compatible_pairs + exchange.compatible
        profile_plan.exchange_domains = profile_plan.exchange_domains
          + (exchange.selected and 1 or 0)
        profile_plan.zero_exchange_domains = profile_plan.zero_exchange_domains
          + exchange.zero_domains
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
            profile_plan.forced_exchange_opportunities = profile_plan.forced_exchange_opportunities
              + 1
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
          refutation = merge_refutation(refutation, ref)
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
              refutation = merge_refutation(refutation, ref)
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
        local all_machine, machine_supply_none = group.all_machine, group.supply_none

        if all_machine and machine_supply_none then
          local forced = false
          if
            state.runtime.normalise_search ~= false
            and #groups == 1
            and #group.ids == #state.intents
          then
            local group_intents = {}
            for ii = 1, #group.ids do
              group_intents[ii] = state.intent_by_id[group.ids[ii]]
            end
            forced = not has_supplier(state, group_intents)
          end
          -- Non-supplying serial transducers have an explicit deterministic
          -- order and can be resolved as one location journal. This avoids
          -- factorially re-enumerating Region and scope-monitor updates.
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
            refutation = merge_refutation(refutation, ref)
            if unknown then
              return nil, refutation, true
            end
          end
        else
          -- A serial-transducer location has one deterministic transition
          -- order. Prefer resolving all currently entered transitions as one
          -- journal: this preserves cases such as two mailbox sends followed
          -- by a close in the same tensor, where every sendability check must
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
              refutation = merge_refutation(refutation, ref)
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
              refutation = merge_refutation(refutation, ref)
              if unknown then
                return nil, refutation, true
              end
            end
          end
        end
      end

      local suppliers, supplier_refutation_hit = {}, false
      if frontier.accepts_participant_supply then
        suppliers, supplier_refutation_hit = supplier_rows(state)
      end
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
      local row = suppliers[1]
      if row then
        local included = clone_state(state)
        add_root(included, row.id)
        local found, ref, unknown = dfs(included)
        if found then
          return found
        end
        refutation = merge_refutation(refutation, ref)
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
        refutation = merge_refutation(refutation, ref)
        if unknown then
          return nil, refutation, true
        end
      end

      local terminal = terminal_refutation(state)
      refutation = merge_refutation(refutation, terminal)
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
  local focus_request = requests[focus_id]
  local focus_metadata = focus_request and (focus_request.metadata or focus_request.footprint)
  if component and focus_metadata and (focus_metadata.node_kinds or {}).choice then
    runtime:_ensure_component_coordinator(component)
  end
  local focus_nodes = focus_metadata and focus_metadata.nodes or 0
  local frontier_size = component and component.size or #runtime.pending
  local structurally_large = frontier_size >= 16 or focus_nodes >= 16
  local state_memoization_possible = runtime.state_memoization ~= false
    and (runtime.state_memoization_min_steps == 0 or structurally_large)
  local refutation_cache_possible = runtime.refutation_cache ~= false
    and (runtime.refutation_cache_min_steps == 0 or structurally_large)

  local state = {
    runtime = runtime,
    requests = requests,
    focus = focus_id,
    choice_generation = component and component.choice_generation or nil,
    tasks = {},
    active = {},
    roots = {},
    groups = {},
    views = {},
    intents = {},
    intent_by_id = {},
    effects = {},
    used_fallback = false,
    negative_checks = {},
    fallback_interests = {},
    excluded_roots = {},
    next_task = 0,
    next_group = 0,
    next_view = 0,
    next_intent = 0,
    next_machine_serial = 0,
    search_steps = 0,
    search_work = { steps = 0 },
    search_limit = search_limit or runtime.search_limit,
    profile_plan = profile_plan,
    state_memoization_possible = state_memoization_possible or nil,
    state_memoization_min_steps = state_memoization_possible
        and runtime.state_memoization_min_steps
      or nil,
    refutation_cache_possible = refutation_cache_possible or nil,
    refutation_cache_min_steps = refutation_cache_possible and runtime.refutation_cache_min_steps
      or nil,
    component = (state_memoization_possible or refutation_cache_possible) and component or nil,
    plan_id = (state_memoization_possible or refutation_cache_possible) and runtime.stats.plans
      or nil,
  }
  add_root(state, focus_id)
  local candidate, refutation, unknown = dfs(state)
  state.search_steps = state.search_work.steps
  if candidate then
    runtime._last_search_steps = candidate.search_steps
  end
  if state.plan_id then
    SearchCache.finish(state)
  end
  if profile_plan then
    profile_plan.search_steps = state.search_steps
    if candidate then
      profile_plan.participants = #(candidate.participants or {})
      profile_plan.observations = map_count(candidate.observations)
      profile_plan.writes = map_count(candidate.writes)
      profile_plan.effects = #(candidate.effects or {})
    end
    instrumentation:finish_plan(
      profile_plan,
      candidate and 'found' or (unknown and 'unknown' or 'retry')
    )
  end
  return candidate, refutation, unknown
end

return M

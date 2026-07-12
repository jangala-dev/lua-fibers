-- Production trail-based proof-search evaluator.
-- The copy-on-branch oracle lives in fibers/internal/reference_machine.lua.

local Op = require('fibers.atoms.op')
local Store = require('fibers.kernel.store')
local IR = require('fibers.kernel.ir')
local ChoiceOrder = require('fibers.kernel.choice_order')

local M = {}

local unpack_ = table.unpack or unpack
local pack_ = Op._pack

local function unpack_pack(p)
  return unpack_(p, 1, p.n or #p)
end

local function copy_array(xs)
  local out = {}
  for i = 1, #(xs or {}) do out[i] = xs[i] end
  return out
end

local function copy_scope_path(path)
  local out = {}
  for i = 1, #(path or {}) do
    local e = path[i]
    out[i] = { group_id = e.group_id, mode = e.mode, lane = e.lane }
  end
  return out
end

local Trail = {}
Trail.__index = Trail

function Trail.new(stats)
  return setmetatable({ n = 0, kinds = {}, targets = {}, keys = {}, olds = {},
    stats = stats, next_mark = 0, current_mark = 0, touched = { [0] = {} } }, Trail)
end

function Trail:mark()
  self.next_mark = self.next_mark + 1
  local mark = { n = self.n, id = self.next_mark, parent = self.current_mark }
  self.current_mark = mark.id; self.touched[mark.id] = {}
  return mark
end

local function add_entry(self, kind, target, key, old)
  local n = self.n + 1; self.n = n
  self.kinds[n], self.targets[n], self.keys[n], self.olds[n] = kind, target, key, old
  if self.stats then self.stats.trail_entries = (self.stats.trail_entries or 0) + 1 end
end

function Trail:set(target, key, value)
  if target[key] == value then return end
  add_entry(self, 1, target, key, target[key]); target[key] = value
end

function Trail:push(target, value)
  add_entry(self, 2, target, nil, #target); target[#target + 1] = value
end

function Trail:snapshot_view(view)
  local touched = self.touched[self.current_mark]
  if touched[view] then return end
  touched[view] = true
  add_entry(self, 3, view, nil, Store.clone_view(view))
end

local function restore_view(view, old)
  view.cells, view.delta = old.cells, old.delta
  view.root_id, view.scope_path, view.merged = old.root_id, old.scope_path, old.merged
end

function Trail:rollback(mark)
  for i = self.n, mark.n + 1, -1 do
    local kind, target, key, old = self.kinds[i], self.targets[i], self.keys[i], self.olds[i]
    if kind == 1 then target[key] = old
    elseif kind == 2 then for j = #target, old + 1, -1 do target[j] = nil end
    elseif kind == 3 then restore_view(target, old)
    else error('unknown trail entry: ' .. tostring(kind), 0) end
    self.kinds[i], self.targets[i], self.keys[i], self.olds[i] = nil, nil, nil, nil
  end
  self.n = mark.n; self.touched[mark.id] = nil; self.current_mark = mark.parent
  if self.stats then self.stats.rollbacks = (self.stats.rollbacks or 0) + 1 end
end

function Trail:reset()
  self.n, self.kinds, self.targets, self.keys, self.olds = 0, {}, {}, {}, {}
  self.current_mark, self.touched = 0, { [0] = {} }
end

local function setv(state, target, key, value) state.trail:set(target, key, value) end
local function pushv(state, target, value) state.trail:push(target, value) end


local function new_view(state, root_id, scope_path, source_view_id)
  state.next_view = state.next_view + 1
  local id = state.next_view
  local source = source_view_id and state.views[source_view_id] or nil
  setv(state, state.views, id, Store.new_view(root_id, copy_scope_path(scope_path), source))
  return id
end

local function merge_group_views(state, group)
  local parent = state.views[group.parent_view]
  local children = {}
  for i = 1, group.count do children[i] = state.views[group.lane_views[i]] end
  return Store.merge_views(parent, children, group.mode, state.trail)
end

local function compose_wrap(inner, fn)
  return function(packed)
    if inner then packed = inner(packed) end
    return pack_(fn(unpack_pack(packed)))
  end
end

local function product_wrap(lane_outcomes)
  local wraps, has_wrap = {}, false
  for i = 1, #lane_outcomes do
    wraps[i] = lane_outcomes[i] and lane_outcomes[i].wrap or false
    if wraps[i] then has_wrap = true end
  end
  if not has_wrap then return nil end
  return function(packed)
    local rows = packed[1]
    for i = 1, #wraps do if wraps[i] then rows[i] = wraps[i](rows[i]) end end
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

  if group.completed < group.count then return true end
  if not merge_group_views(state, group) then return false end

  local rows = { _fibers_rows = true }
  for i = 1, group.count do rows[i] = group.lane_outcomes[i].pack end
  local parent = state.tasks[group.parent_task]
  setv(state, parent, 'status', 'active')
  return complete_task(state, parent, {
    pack = pack_(rows),
    wrap = product_wrap(group.lane_outcomes),
  })
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
      if outcome.wrap then error('transactional continuation attempted to consume a wrapped result', 0) end
      local request = state.roots[task.root_id].request
      if frame.phase == 'guard' then
        local cached = request.memo[frame.cache_key]
        if not cached then
          cached = state.runtime:_call_in_phase('guard', 'callback_error', frame.fn, { runtime = state.runtime, now = function() return state.runtime:now() end })
          if not Op.is_op(cached) then error('guard callback must return an Op', 0) end
          request.memo[frame.cache_key] = cached
        end
        setv(state, task, 'expr', cached)
      elseif frame.phase == 'map' then
        setv(state, task, 'expr', Op.always(state.runtime:_call_in_phase('map', 'callback_error', frame.fn, unpack_pack(outcome.pack))))
      else
        local next_op = state.runtime:_call_in_phase('and_then', 'callback_error', frame.fn, unpack_pack(outcome.pack))
        if not Op.is_op(next_op) then error('and_then callback must return an Op', 0) end
        setv(state, task, 'expr', next_op)
      end
      add_active(state, task.id)
      return true

    elseif frame.kind == 'wrap' then
      outcome = { pack = outcome.pack, wrap = compose_wrap(outcome.wrap, frame.fn) }

    elseif frame.kind == 'group_lane' then
      return finish_group_lane(state, task, frame, outcome)

    else
      error('unknown evaluator frame: ' .. tostring(frame.kind), 0)
    end
  end
end

local function add_root(state, root_id)
  if state.roots[root_id] then return end
  local request = state.requests[root_id]
  if not request then return end

  local view_id = new_view(state, root_id, {})
  state.next_task = state.next_task + 1
  local task_id = state.next_task
  setv(state, state.tasks, task_id, {
    id = task_id,
    root_id = root_id,
    expr = request.op,
    frames = {},
    view_id = view_id,
    scope_path = {},
    status = 'active',
    choice_serial = 0,
  })
  setv(state, state.roots, root_id, {
    request = request,
    view_id = view_id,
    done = false,
    scope = scope,
    scope_stack = scope and { scope } or {},
  })
  pushv(state, state.active, task_id)
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
  setv(state, state.groups, group_id, group)
  setv(state, task, 'status', 'waiting_group')

  for i = 1, #op.lanes do
    local path = copy_scope_path(task.scope_path)
    path[#path + 1] = { group_id = group_id, mode = op.mode, lane = i }
    local view_id = new_view(state, task.root_id, path, task.view_id)
    setv(state, group.lane_views, i, view_id)
    state.next_task = state.next_task + 1
    local child_id = state.next_task
    setv(state, state.tasks, child_id, {
      id = child_id,
      root_id = task.root_id,
      expr = op.lanes[i],
      frames = { { kind = 'group_lane', group_id = group_id, lane = i } },
      view_id = view_id,
      scope_path = path,
      status = 'active',
      choice_serial = 0,
    })
    pushv(state, state.active, child_id)
  end
end

local function same_root_compatible(a, b)
  local pa, pb = a.scope_path, b.scope_path
  local n = math.min(#pa, #pb)
  for i = 1, n do
    local x, y = pa[i], pb[i]
    if x.group_id ~= y.group_id then return false end
    if x.lane ~= y.lane then return x.mode == 'interacting' end
  end
  return false
end

local function intents_compatible(a, b)
  if a.kind ~= 'exchange' or b.kind ~= 'exchange' then return false end
  if a.resource ~= b.resource then return false end
  if a.role == b.role then return false end
  if a.root_id ~= b.root_id then return true end
  return same_root_compatible(a, b)
end

local function remove_intent_ids(state, ids)
  local remove = {}
  for i = 1, #ids do remove[ids[i]] = true end
  local kept = {}
  for i = 1, #state.intents do
    if not remove[state.intents[i].id] then kept[#kept + 1] = state.intents[i] end
  end
  setv(state, state, 'intents', kept)
end

local function block_intent(state, task, program)
  state.next_intent = state.next_intent + 1
  setv(state, task, 'status', 'blocked')
  pushv(state, state.intents, {
    id = state.next_intent,
    kind = program.kind,
    task_id = task.id,
    root_id = task.root_id,
    program = program,
    resource = program.resource or program.group,
    role = program.role,
    value = program.value,
    scope_path = copy_scope_path(task.scope_path),
    interest = type(program.interest) == 'function' and program.interest(state.runtime, program) or program.interest,
    absence_check = program.absence_check,
  })
end

local function match_intents(state, i, j)
  local a, b = state.intents[i], state.intents[j]
  local kept = {}
  for k = 1, #state.intents do if k ~= i and k ~= j then kept[#kept + 1] = state.intents[k] end end
  setv(state, state, 'intents', kept)
  local put = a.role == 'put' and a or b
  local get = a.role == 'get' and a or b
  local put_task = state.tasks[put.task_id]
  local get_task = state.tasks[get.task_id]
  if not complete_task(state, put_task, { pack = pack_(true) }) then return false end
  if not complete_task(state, get_task, { pack = pack_(put.value) }) then return false end
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
  return { runtime = state.runtime, now = function() return state.runtime:now() end }
end

local function machine_probe(state, program, value)
  local t, payload = program.transition, program.payload or {}
  if type(t.ready) == 'function' then
    local out = t.ready(value, payload, machine_context(state))
    return out ~= nil and out ~= false and not is_machine_wait(out)
  end
  local packed = pack_(t.step(value, payload, machine_context(state)))
  local first = packed[1]
  if packed.n == 1 and is_machine_wait(first) then return false end
  if is_machine_ready(first) then return true end
  if t.mode == 'update' then return packed.n > 0 end
  return packed.n > 0 and packed[1] ~= nil
end

local function run_machine_transition(state, program, value)
  local t, payload = program.transition, program.payload or {}
  local packed = pack_(t.step(value, payload, machine_context(state)))
  local first = packed[1]
  if packed.n == 1 and is_machine_wait(first) then return nil end
  if is_machine_ready(first) then
    if t.mode == 'query' and first.writes then return nil end
    return {
      writes = first.writes == true,
      value = first.value,
      result = first.pack or pack_(),
    }
  end
  if t.mode == 'update' then
    if packed.n == 0 then return nil end
    local out = { n = packed.n - 1 }
    for i = 2, packed.n do out[i - 1] = packed[i] end
    out._fibers_pack = true
    return { writes = true, value = packed[1], result = out }
  end
  if packed.n == 0 or packed[1] == nil then return nil end
  if t.mode == 'select' then
    local out = { n = packed.n - 1, _fibers_pack = true }
    for i = 2, packed.n do out[i - 1] = packed[i] end
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
    end, program.transition.supply, state.trail)
    local r = run_machine_transition(state, program, value)
    if not r then return false end
    if r.writes then
      state.next_machine_serial = state.next_machine_serial + 1
      Store.stage(state.views[task.view_id], program.location, {
        kind = 'machine', steps = { { serial = state.next_machine_serial, value = r.value } },
      }, state.trail)
    else
      -- Ensure the location version is part of the observation set.
      Store.cell(state.views[task.view_id], program.location, state.trail)
    end
    resolved[#resolved + 1] = { intent = intent, task = task, result = r.result }
  end
  local ids = {}
  for i = 1, #selected do ids[i] = selected[i].id end
  remove_intent_ids(state, ids)
  for i = 1, #resolved do
    if not complete_task(state, resolved[i].task, { pack = resolved[i].result }) then return false end
  end
  return true
end

local function resolve_claims(state, intent_ids)
  local selected, by_id = {}, {}
  for i = 1, #intent_ids do by_id[intent_ids[i]] = true end
  for i = 1, #state.intents do
    local intent = state.intents[i]
    if by_id[intent.id] then selected[#selected + 1] = intent end
  end
  table.sort(selected, function(a, b) return a.id < b.id end)
  if #selected == 0 then return false end
  if selected[1].kind == 'machine_transition' then
    return resolve_machine_transitions(state, selected)
  end

  local resolved = {}
  for i = 1, #selected do
    local intent = selected[i]
    local program = intent.program
    local loc = program.location
    local task = state.tasks[intent.task_id]
    local value = Store.project(state, task, loc, program.orientation or program.demand_tag, state.trail)
    if value == nil then return false end
    local resolution = Store.evaluate_claim(program, value)
    if not resolution then return false end

    -- Stage immediately, but do not complete the task yet. Later claims see
    -- the mutation through the ordinary provenance rules.
    if resolution.patch then Store.stage(state.views[task.view_id], loc, resolution.patch, state.trail) end
    resolved[#resolved + 1] = {
      intent = intent,
      task = task,
      result = resolution.result,
    }
  end

  remove_intent_ids(state, intent_ids)
  for i = 1, #resolved do
    local r = resolved[i]
    if not complete_task(state, r.task, { pack = r.result }) then return false end
  end
  return true
end

local function witness_cursor(state, intent)
  local program = intent.program
  local task = state.tasks[intent.task_id]
  local function ready(value)
    return IR.witness_ready(program, value, program.payload or {}, {})
  end
  local value = Store.project_machine(state, task, program.location, ready,
    program.supply or 'interacting', state.trail)
  return IR.open_witness_cursor(program, value, program.payload or {}, {})
end

local function resolve_witness(state, intent_id, alt)
  local intent, intent_pos
  for i = 1, #state.intents do
    if state.intents[i].id == intent_id then intent, intent_pos = state.intents[i], i; break end
  end
  if not intent or not alt then return false end
  local task = state.tasks[intent.task_id]
  if alt.writes ~= false then
    state.next_machine_serial = state.next_machine_serial + 1
    Store.stage(state.views[task.view_id], intent.program.location, {
      kind = 'machine', steps = { { serial = state.next_machine_serial, value = alt.value } },
    }, state.trail)
  else Store.cell(state.views[task.view_id], intent.program.location, state.trail) end
  local kept = {}
  for i = 1, #state.intents do if i ~= intent_pos then kept[#kept + 1] = state.intents[i] end end
  if state.trail then state.trail:set(state, 'intents', kept) else state.intents = kept end
  local packed = alt.result
  if not (type(packed) == 'table' and packed._fibers_pack == true) then
    if type(packed) == 'table' and packed.n ~= nil then packed._fibers_pack = true else packed = pack_(packed) end
  end
  return complete_task(state, task, { pack = packed })
end

local function claim_groups(state)
  local groups, order = {}, {}
  for i = 1, #state.intents do
    local intent = state.intents[i]
    if intent.kind == 'claim' or intent.kind == 'conditional_claim' or intent.kind == 'machine_transition' then
      local group_key = intent.program.group or intent.program.location
      local key = tostring(group_key)
      local group = groups[key]
      if not group then
        group = { key = group_key, ids = {} }
        groups[key] = group
        order[#order + 1] = group
      end
      group.ids[#group.ids + 1] = intent.id
    end
  end
  return order
end

local function resolve_claim_set(state, group, ids)
  -- Total machine updates on a location are unavoidable members of the
  -- current world.  Include them whenever resolving another transition on
  -- that location so a constraining sibling cannot be bypassed by resolving
  -- a partial subset first.
  local selected = {}
  for i = 1, #ids do selected[ids[i]] = true end
  for i = 1, #(group.ids or {}) do
    local id = group.ids[i]
    for j = 1, #state.intents do
      local intent = state.intents[j]
      if intent.id == id and intent.kind == 'machine_transition'
          and intent.program.transition.mode == 'update' then
        selected[id] = true
        break
      end
    end
  end
  local expanded = {}
  for id in pairs(selected) do expanded[#expanded + 1] = id end
  table.sort(expanded)
  return resolve_claims(state, expanded)
end

local function final_candidate(state)
  for _, root in pairs(state.roots) do
    if not root.done then return nil end
  end
  if #state.intents > 0 then return nil end

  local root_views = {}
  for _, root in pairs(state.roots) do root_views[#root_views + 1] = state.views[root.view_id] end
  local observations, writes = Store.collect_candidate(root_views)
  if not observations then return nil end

  -- Domain constraints are fixed substrate rules, not resource callbacks.
  for loc, patch in pairs(writes) do
    if loc.domain == 'counter' then
      local final = Store.apply_patch_value(loc, loc.value, patch)
      local owner = loc.owner
      if owner.min ~= nil and final < owner.min then return nil end
      if owner.max ~= nil and final > owner.max then return nil end
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
    effects = copy_array(state.effects),
    negative_guard = state.used_fallback == true,
    epoch = state.runtime.epoch,
    pending_generation = state.runtime.pending_generation,
    negative_checks = copy_array(state.negative_checks),
    fallback_interests = copy_array(state.fallback_interests),
    search_steps = state.search_steps,
  }

  -- Effect merge and preparation are part of world admissibility. A structured
  -- refusal therefore rejects this derivation and lets ordinary search
  -- backtrack to another choice, partner or fallback world.
  local prepared = state.runtime:_prepare_effects(candidate)
  if not prepared then return nil end
  candidate.prepared_effects = prepared
  return candidate
end

local function execute_program(state, task, program)
  if not program or program._fibers_program ~= true then
    error('primitive payload is not a kernel programme', 0)
  end

  if program.kind == 'exchange' then
    block_intent(state, task, program)
    return true
  end

  if program.kind == 'snapshot' then
    local resource = program.resource
    local view = state.views[task.view_id]
    if program.snapshot_kind == 'keyed' then
      local entries, keys = {}, {}
      for k in pairs(resource.entries) do keys[k] = true end
      for k in pairs(resource._locations) do keys[k] = true end
      for k in pairs(keys) do
        local value = Store.read(view, resource:_location(k), state.trail)
        if value ~= Store.ABSENT then
          if resource._nil_sentinel and value == resource._nil_sentinel then entries[k] = nil else entries[k] = value end
        end
      end
      return complete_task(state, task, { pack = pack_({ entries = entries, version = resource.version }) })
    elseif program.snapshot_kind == 'index' then
      local value = Store.read(view, resource._location, state.trail)
      local entries = {}
      for k, e in pairs(value or {}) do entries[k] = { key = e.key, rank = e.rank, value = e.value, seq = e.seq } end
      return complete_task(state, task, { pack = pack_({ entries = entries, version = resource.version }) })
    elseif program.snapshot_kind == 'lease' then
      local holders = {}
      local subjects = {}
      for s in pairs(resource.holders or {}) do subjects[s] = true end
      for s in pairs(resource._locations or {}) do subjects[s] = true end
      for subject in pairs(subjects) do
        local loc = resource:_location(subject)
        local hs = Store.read(view, loc, state.trail)
        holders[subject] = {}
        for owner, mode in pairs(hs or {}) do holders[subject][owner] = mode end
      end
      return complete_task(state, task, { pack = pack_({ holders = holders, version = resource.version }) })
    end
    error('unknown snapshot kind', 0)
  end

  local view = state.views[task.view_id]
  local loc = program.location

  if program.kind == 'version_wait' then
    if loc.version ~= program.version then
      Store.cell(view, loc, state.trail)
      return complete_task(state, task, { pack = pack_(Store.read(view, loc, state.trail), loc.version) })
    end
    program.observed_version = loc.version
    block_intent(state, task, program)
    return true
  end

  if program.kind == 'read' then
    return complete_task(state, task, { pack = Store.result_pack(program, Store.read(view, loc, state.trail)) })
  end

  if program.kind == 'patch' then
    Store.stage(view, loc, program.patch, state.trail)
    return complete_task(state, task, { pack = Store.result_pack(program, Store.read(view, loc, state.trail)) })
  end

  if program.kind == 'claim' or program.kind == 'machine_transition' or program.kind == 'witness_transition' then
    block_intent(state, task, program)
    return true
  end

  if program.kind == 'conditional_claim' then
    local value = Store.read(view, loc, state.trail)
    if Store.predicate_holds(program, value) then
      Store.stage(view, loc, program.immediate_patch, state.trail)
      return complete_task(state, task, { pack = Store.result_pack(program, value) })
    end
    block_intent(state, task, program)
    return true
  end

  error('unknown programme kind: ' .. tostring(program.kind), 0)
end

local function merge_refutation(dst, src)
  if not src then return dst end
  dst = dst or { interests = {}, checks = {} }
  local seen_i, seen_c = {}, {}
  for i = 1, #dst.interests do seen_i[dst.interests[i].id or tostring(dst.interests[i])] = true end
  for i = 1, #dst.checks do seen_c[dst.checks[i].id or tostring(dst.checks[i])] = true end
  for i = 1, #(src.interests or {}) do
    local x = src.interests[i]
    local id = x.id or tostring(x)
    if not seen_i[id] then seen_i[id] = true; dst.interests[#dst.interests + 1] = x end
  end
  for i = 1, #(src.checks or {}) do
    local x = src.checks[i]
    local id = x.id or tostring(x)
    if not seen_c[id] then seen_c[id] = true; dst.checks[#dst.checks + 1] = x end
  end
  return dst
end

local function terminal_refutation(state)
  local out = { interests = {}, checks = {} }
  for i = 1, #state.intents do
    local intent = state.intents[i]
    if intent.interest then out.interests[#out.interests + 1] = intent.interest end
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
        validate = function() return loc.version == observed_version end,
      }
    end
  end
  return out
end

local function collect_defeat_effects(expr, out)
  out = out or {}
  if not expr then return out end
  local kind = expr.kind
  if kind == 'annotated' then
    for i = 1, #(expr.defeats or {}) do out[#out + 1] = expr.defeats[i] end
    return collect_defeat_effects(expr.p, out)
  elseif kind == 'product' then
    for i = 1, #(expr.lanes or {}) do collect_defeat_effects(expr.lanes[i], out) end
  elseif kind == 'choice' then
    for i = 1, #(expr.choices or {}) do collect_defeat_effects(expr.choices[i], out) end
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
  if #extra == 0 then return candidate end
  for i = 1, #extra do candidate.effects[#candidate.effects + 1] = extra[i] end
  local prepared = runtime:_prepare_effects(candidate)
  if not prepared then return nil end
  candidate.prepared_effects = prepared
  return candidate
end

local function intent_accepts_participant_supply(intent)
  if not intent then return false end
  if intent.kind == 'exchange' then return true end
  if intent.kind == 'claim' or intent.kind == 'conditional_claim' then return true end
  if intent.kind == 'witness_transition' then
    return intent.program.supply ~= 'none'
  end
  if intent.kind == 'machine_transition' then
    return intent.program.transition.supply ~= 'none'
  end
  return false
end

local function state_accepts_participant_supply(state)
  for i = 1, #(state.intents or {}) do
    if intent_accepts_participant_supply(state.intents[i]) then return true end
  end
  return false
end

local function request_may_supply(request, intents)
  return IR.footprint_may_supply(request.footprint or IR.footprint(request.op), intents)
end

local dfs

local function explore(state, prepare)
  local mark = state.trail:mark()
  local ready = prepare == nil or prepare() ~= false
  local found, refutation, unknown
  if ready then found, refutation, unknown = dfs(state) end
  state.trail:rollback(mark)
  return found, refutation, unknown
end

dfs = function(state)
  state.runtime.stats.search_calls = state.runtime.stats.search_calls + 1
  state.search_steps = state.search_steps + 1
  if state.search_steps > state.search_limit then
    return nil, { interests = {}, checks = {} }, true
  end

  while true do
    if state.active_head <= #state.active then
      local task_id = state.active[state.active_head]
      setv(state, state, 'active_head', state.active_head + 1)
      local task = state.tasks[task_id]
      if task and task.status == 'active' then
        local expr, kind = task.expr, task.expr.kind
        if kind == 'always' then
          if not complete_task(state, task, { pack = expr.vals }) then return nil, terminal_refutation(state), false end
        elseif kind == 'and_then' then
          pushv(state, task.frames, { kind = 'bind', fn = expr.fn, phase = expr.callback_phase, cache_key = expr.cache_key })
          setv(state, task, 'expr', expr.p); add_active(state, task.id)
        elseif kind == 'annotated' then
          if expr.post then pushv(state, task.frames, { kind = 'wrap', fn = expr.post }) end
          setv(state, task, 'expr', expr.p); add_active(state, task.id)
        elseif kind == 'consequence' then
          pushv(state, state.effects, expr.effect)
          if not complete_task(state, task, { pack = pack_() }) then return nil, terminal_refutation(state), false end
        elseif kind == 'primitive' then
          if not execute_program(state, task, expr.payload) then return nil, terminal_refutation(state), false end
        elseif kind == 'product' then
          start_product(state, task, expr)
        elseif kind == 'choice' then
          local refutation
          local occurrence = (task.choice_serial or 0) + 1
          setv(state, task, 'choice_serial', occurrence)
          local order = ChoiceOrder.indices(state.runtime, task, occurrence, #(expr.choices or {}))
          for k = 1, #order do
            local i = order[k]
            local found, ref, unknown = explore(state, function()
              setv(state, task, 'expr', expr.choices[i]); add_active(state, task.id)
            end)
            if found then
              local defeats = {}
              for j = 1, #(expr.choices or {}) do if j ~= i then collect_defeat_effects(expr.choices[j], defeats) end end
              found = attach_candidate_effects(state.runtime, found, defeats)
              if found then return found end
            end
            refutation = merge_refutation(refutation, ref)
            if unknown then return nil, refutation, true end
          end
          return nil, refutation or terminal_refutation(state), false
        elseif kind == 'or_else' then
          local found, pref, unknown = explore(state, function()
            setv(state, task, 'expr', expr.p); add_active(state, task.id)
          end)
          if found then return found end
          if unknown then return nil, pref, true end
          local fallback_found, fref, funknown = explore(state, function()
            setv(state, state, 'used_fallback', true)
            for i = 1, #((pref and pref.checks) or {}) do pushv(state, state.negative_checks, pref.checks[i]) end
            for i = 1, #((pref and pref.interests) or {}) do pushv(state, state.fallback_interests, pref.interests[i]) end
            setv(state, task, 'expr', expr.q); add_active(state, task.id)
          end)
          if fallback_found then return fallback_found end
          return nil, fref or { interests = {}, checks = {} }, funknown
        else
          error('unsupported Op kind: ' .. tostring(kind), 0)
        end
      end
    else
      local candidate = final_candidate(state)
      if candidate then return candidate end
      local refutation

      for i = 1, #state.intents do
        for j = i + 1, #state.intents do
          if intents_compatible(state.intents[i], state.intents[j]) then
            local found, ref, unknown = explore(state, function() return match_intents(state, i, j) end)
            if found then return found end
            refutation = merge_refutation(refutation, ref)
            if unknown then return nil, refutation, true end
          end
        end
      end

      for ii = 1, #state.intents do
        local intent = state.intents[ii]
        if intent.kind == 'witness_transition' then
          local cursor = witness_cursor(state, intent)
          while true do
            local alt = cursor:next(); if alt == nil then break end
            local found, ref, unknown = explore(state, function() return resolve_witness(state, intent.id, alt) end)
            if found then return found end
            refutation = merge_refutation(refutation, ref)
            if unknown then return nil, refutation, true end
          end
        end
      end

      local groups = claim_groups(state)
      for gi = 1, #groups do
        local group = groups[gi]
        local all_machine, supply_none = true, true
        for ii = 1, #group.ids do
          local x
          for jj = 1, #state.intents do if state.intents[jj].id == group.ids[ii] then x = state.intents[jj]; break end end
          if not x or x.kind ~= 'machine_transition' then all_machine, supply_none = false, false; break end
          if x.program.transition.supply ~= 'none' then supply_none = false end
        end
        if all_machine and supply_none then
          local found, ref, unknown = explore(state, function() return resolve_claim_set(state, group, group.ids) end)
          if found then return found end
          refutation = merge_refutation(refutation, ref)
          if unknown then return nil, refutation, true end
        else
          if all_machine and #group.ids > 1 then
            local found, ref, unknown = explore(state, function() return resolve_claim_set(state, group, group.ids) end)
            if found then return found end
            refutation = merge_refutation(refutation, ref)
            if unknown then return nil, refutation, true end
          end
          for ii = 1, #group.ids do
            local id = group.ids[ii]
            local found, ref, unknown = explore(state, function() return resolve_claim_set(state, group, { id }) end)
            if found then return found end
            refutation = merge_refutation(refutation, ref)
            if unknown then return nil, refutation, true end
          end
        end
      end

      local ids = {}
      if state_accepts_participant_supply(state) then
        for id in pairs(state.requests) do if not state.roots[id] and not state.excluded_roots[id] then ids[#ids + 1] = id end end
      end
      table.sort(ids)
      if #ids > 0 then
        local id = ids[1]
        if #state.intents > 0 then
          for i = 1, #ids do
            local request = state.requests[ids[i]]
            if request and request_may_supply(request, state.intents) then id = ids[i]; break end
          end
        end
        local found, ref, unknown = explore(state, function() add_root(state, id) end)
        if found then return found end
        refutation = merge_refutation(refutation, ref)
        if unknown then return nil, refutation, true end
        found, ref, unknown = explore(state, function() setv(state, state.excluded_roots, id, true) end)
        if found then return found end
        refutation = merge_refutation(refutation, ref)
        if unknown then return nil, refutation, true end
      end

      refutation = merge_refutation(refutation, terminal_refutation(state))
      return nil, refutation, false
    end
  end
end


function M.search(runtime, requests, focus_id, search_limit)
  if not requests[focus_id] then return nil end
  runtime.stats.plans = runtime.stats.plans + 1
  local state = {
    runtime = runtime, requests = requests, focus = focus_id,
    tasks = {}, active = {}, active_head = 1, roots = {}, groups = {}, views = {},
    intents = {}, effects = {}, used_fallback = false,
    negative_checks = {}, fallback_interests = {}, excluded_roots = {},
    next_task = 0, next_group = 0, next_view = 0, next_intent = 0,
    next_machine_serial = 0, search_steps = 0,
    search_limit = search_limit or runtime.search_limit,
  }
  state.trail = Trail.new(runtime.stats)
  add_root(state, focus_id)
  state.trail:reset()
  local candidate, refutation, unknown = dfs(state)
  if candidate then runtime._last_search_steps = candidate.search_steps end
  return candidate, refutation, unknown
end

return M

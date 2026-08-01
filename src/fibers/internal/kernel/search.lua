-- Transactional search over one speculative journal.
--
-- The kernel has one mutable speculative state, one rollback trail and one
-- depth-first search. Deterministic operation reduction runs to a fixed point;
-- checkpoints are created only for genuine alternatives.

local Values = require('fibers.internal.values')
local Journal = require('fibers.internal.kernel.journal')
local Candidate = require('fibers.internal.kernel.candidate')
local Activation = require('fibers.internal.kernel.activation')
local Proof = require('fibers.internal.proof')
local Operation = require('fibers.internal.operation')
local Algebra = require('fibers.internal.kernel.algebra')

local M = {}
local Search = {}
Search.__index = Search
local EMPTY = {}
local ORDER_MOD, ORDER_MUL = 2147483647, 48271
local function order_residue(value)
  return math.floor(tonumber(value) or 0) % ORDER_MOD
end
local function order_step(state, salt)
  return (state * ORDER_MUL + order_residue(salt)) % ORDER_MOD
end
local function choice_indices(engine, task, occurrence, count, generation)
  local order = {}
  for i = 1, count do
    order[i] = i
  end
  if count < 2 then
    return order
  end
  local state = order_residue(engine.choice_seed)
  if state == 0 then
    state = 1
  end
  state = order_step(state, engine.epoch or 0)
  state = order_step(state, generation or engine.pending_generation or 0)
  state = order_step(state, task.root.request.order or 0)
  state = order_step(state, task.serial or 0)
  state = order_step(state, occurrence or 0)
  for i = count, 2, -1 do
    state = order_step(state, i)
    local j = (state % i) + 1
    order[i], order[j] = order[j], order[i]
  end
  return order
end

local function frontier_active(intent)
  return intent and intent.active and intent or nil
end

local function frontier_rule(intent)
  if intent and intent.kind == 'transition' then
    return Operation.transition_behaviour(intent.spec)
  end
end

local BULK_MATCH_THRESHOLD = 32

-- Return one complete left-to-right matching, or nil. Edges may be stored
-- in a map keyed by the left item or in a named field on each left row.
local function bipartite_matching(left, edge_map, edge_field, right_field)
  local owner, selected = {}, {}
  local function augment(item, seen)
    local edges = edge_map and edge_map[item] or item[edge_field]
    for i = 1, #edges do
      local edge = edges[i]
      local right = right_field and edge[right_field] or edge
      if not seen[right] then
        seen[right] = true
        if not owner[right] or augment(owner[right], seen) then
          owner[right], selected[item] = item, edge
          return true
        end
      end
    end
    return false
  end
  for i = 1, #left do
    if not augment(left[i], {}) then
      return nil
    end
  end
  return selected
end

local function maximum_exchange_matching(resources)
  local matching = {}
  for r = 1, #resources do
    local info = resources[r]
    if not info.adjacency then
      for i = 1, #info.puts do
        matching[#matching + 1] = { info.puts[i], info.gets[i] }
      end
    else
      local selected = bipartite_matching(info.puts, info.adjacency)
      if not selected then
        return false
      end
      for i = 1, #info.puts do
        local put = info.puts[i]
        matching[#matching + 1] = { put, selected[put] }
      end
    end
  end
  table.sort(matching, function(a, b)
    return math.min(a[1].serial, a[2].serial) < math.min(b[1].serial, b[2].serial)
  end)
  return matching
end

-- One exchange scan supplies fail-first degrees and exact closed-frontier
-- reductions. Large closed resources begin as implicit complete bipartite
-- graphs; adjacency is materialised only when the first missing edge is found.
local function exchange_frontier(state, compatible, closed)
  local degree, active_exchange = {}, 0
  local analyse_matching = closed and (state.active_intent_count or 0) >= BULK_MATCH_THRESHOLD
  local resources, by_resource

  -- Count large closed resources before their quadratic compatibility scan.
  -- An unequal role count is already a complete refutation.
  if analyse_matching then
    resources, by_resource = {}, {}
    for resource, bucket in pairs(state.exchange_buckets or EMPTY) do
      local put_count, get_count = 0, 0
      for i = 1, #(bucket.put or EMPTY) do
        if frontier_active(bucket.put[i]) then
          put_count = put_count + 1
        end
      end
      for i = 1, #(bucket.get or EMPTY) do
        if frontier_active(bucket.get[i]) then
          get_count = get_count + 1
        end
      end
      if put_count + get_count > 0 then
        if put_count ~= get_count then
          return {
            selected = nil,
            selected_degree = 0,
            partners = {},
            zero_domains = 0,
            active = state.active_intent_count or 0,
            balanced = false,
          }
        end
        local info = { puts = {}, gets = {} }
        resources[#resources + 1], by_resource[resource] = info, info
      end
    end
  end

  local balanced = true
  for resource, bucket in pairs(state.exchange_buckets or EMPTY) do
    local raw_puts, raw_gets = bucket.put or EMPTY, bucket.get or EMPTY
    local put_count, get_count = 0, 0
    local info = by_resource and by_resource[resource]
    local gets = raw_gets
    if info then
      gets = info.gets
      for i = 1, #raw_gets do
        local get = frontier_active(raw_gets[i])
        if get then
          gets[#gets + 1] = get
        end
      end
    end

    for i = 1, #raw_puts do
      local put = frontier_active(raw_puts[i])
      if put then
        active_exchange, put_count = active_exchange + 1, put_count + 1
        local neighbours
        if info then
          info.puts[#info.puts + 1] = put
          if info.adjacency then
            neighbours = {}
            info.adjacency[put] = neighbours
          end
        end
        for j = 1, #gets do
          local get = info and gets[j] or frontier_active(gets[j])
          if get then
            if compatible(put, get) then
              degree[put] = (degree[put] or 0) + 1
              degree[get] = (degree[get] or 0) + 1
              if neighbours then
                neighbours[#neighbours + 1] = get
              end
            elseif info and not info.adjacency then
              -- Every previous row and the current row prefix was complete.
              info.adjacency = {}
              for p = 1, #info.puts - 1 do
                local all = {}
                for g = 1, #gets do
                  all[g] = gets[g]
                end
                info.adjacency[info.puts[p]] = all
              end
              neighbours = {}
              for g = 1, j - 1 do
                neighbours[g] = gets[g]
              end
              info.adjacency[put] = neighbours
            end
          end
        end
      end
    end

    if info then
      get_count = #gets
      active_exchange = active_exchange + get_count
    else
      for i = 1, #raw_gets do
        if frontier_active(raw_gets[i]) then
          active_exchange, get_count = active_exchange + 1, get_count + 1
        end
      end
    end
    if closed and put_count ~= get_count then
      balanced = false
    end
  end

  local selected, selected_degree, zero_domains = nil, nil, 0
  for _, bucket in pairs(state.exchange_buckets or EMPTY) do
    for _, role in ipairs({ 'put', 'get' }) do
      for i = 1, #(bucket[role] or EMPTY) do
        local intent = frontier_active(bucket[role][i])
        if intent then
          local n = degree[intent] or 0
          if n == 0 then
            zero_domains = zero_domains + 1
          elseif
            not selected_degree
            or n < selected_degree
            or (n == selected_degree and intent.serial < selected.serial)
          then
            selected, selected_degree = intent, n
          end
        end
      end
    end
  end

  local partners = {}
  if selected then
    local info = by_resource and by_resource[selected.resource]
    if info and not info.adjacency then
      local values = selected.role == 'put' and info.gets or info.puts
      for i = 1, #values do
        partners[i] = values[i]
      end
    elseif info and selected.role == 'put' then
      local neighbours = info.adjacency[selected] or EMPTY
      for i = 1, #neighbours do
        partners[i] = neighbours[i]
      end
    else
      local bucket = state.exchange_buckets[selected.resource]
      local ids = bucket and bucket[selected.role == 'put' and 'get' or 'put'] or EMPTY
      for i = 1, #ids do
        local partner = frontier_active(ids[i])
        if partner and compatible(selected, partner) then
          partners[#partners + 1] = partner
        end
      end
    end
  end

  local matching
  if resources and balanced and zero_domains == 0 then
    matching = maximum_exchange_matching(resources)
  end
  return {
    selected = selected,
    selected_degree = selected_degree or 0,
    partners = partners,
    zero_domains = zero_domains,
    active = active_exchange,
    balanced = balanced,
    matching = matching,
  }
end

local function claim_frontier(state)
  local groups = {}
  for location, ids in pairs(state.transition_buckets or EMPTY) do
    local group
    for i = 1, #ids do
      local intent = frontier_active(ids[i])
      local rule = frontier_rule(intent)
      if rule and not rule.enumerable then
        if not group then
          group = { key = location, intents = {}, all_machine = true, accepts_supply = false }
          groups[#groups + 1] = group
        end
        group.intents[#group.intents + 1] = intent
        if not rule.serial then
          group.all_machine = false
        end
        if not rule.serial or rule.accepts_supply then
          group.accepts_supply = true
        end
      end
    end
  end
  table.sort(groups, function(a, b)
    if #a.intents ~= #b.intents then
      return #a.intents < #b.intents
    end
    local ai, bi =
      a.intents[1] and a.intents[1].serial or math.huge, b.intents[1] and b.intents[1].serial or math.huge
    return ai < bi
  end)
  return groups
end

local function indexed_active(intents)
  local values = {}
  for i = 1, #(intents or EMPTY) do
    local intent = frontier_active(intents[i])
    if intent then
      values[#values + 1] = intent
    end
  end
  return values
end

local function analyse_frontier(state, compatible, closed_exchange)
  local witnesses, choices = indexed_active(state.witnesses), indexed_active(state.choices)
  table.sort(choices, function(a, b)
    local ac, bc = #(a.order or EMPTY), #(b.order or EMPTY)
    return ac ~= bc and ac < bc or ac == bc and a.serial < b.serial
  end)
  local exchange = exchange_frontier(state, compatible, closed_exchange)
  return {
    exchange = exchange,
    witnesses = witnesses,
    claims = claim_frontier(state),
    choices = choices,
    accepts_participant_supply = exchange.active > 0 or (state.accepts_supply_count or 0) > 0,
  }
end

local unpack_ = table.unpack or unpack
local pack_ = Values.pack
local function leaf_kind(leaf)
  return Operation.leaf_kind(leaf)
end
local PACK_TRUE = pack_(true)
local ACT = {
  annotated = {},
  and_then_prefix = {},
  and_then_result = {},
  choice = {},
  exchange = {},
  fallback = {},
  guard = {},
  map = {},
  preferred = {},
  product_lane = {},
  product_result = {},
  transition = {},
  witness = {},
}

local function unpack_pack(p)
  return unpack_(p, 1, p.n or #p)
end

local function new_outcome(task, packed, wrap)
  return { pack = packed, wrap = wrap, activation = task and task.activation or nil }
end

local function map_count(values)
  local count = 0
  for _ in pairs(values or {}) do
    count = count + 1
  end
  return count
end

local function setv(state, target, key, value)
  state.journal:set(target, key, value)
end

local function pushv(state, target, value)
  state.journal:push(target, value)
end

local function bump(state, target, key, amount)
  setv(state, target, key, (target[key] or 0) + (amount or 1))
  return target[key]
end

local function ensure_table(state, key)
  local value = state[key]
  if not value then
    value = {}
    setv(state, state, key, value)
  end
  return value
end

local function advance_activation(state, task, ...)
  setv(state, task, 'activation', Activation.child(task.activation, ...))
end

local function copy_array(xs, out)
  out = out or {}
  for i = 1, #(xs or {}) do
    out[i] = xs[i]
  end
  return out
end

local function new_segment(state, root, scope_path, source)
  return state.journal:new_segment(root, scope_path, source)
end

local function merge_group_views(state, group)
  local parent = group.parent_segment
  local children = {}
  for i = 1, group.count do
    children[i] = group.lane_segments[i]
  end
  return Journal.join_segments(parent, children, group.mode)
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
  local count, wraps = #lane_outcomes, nil
  for i = 1, count do
    local wrap = lane_outcomes[i] and lane_outcomes[i].wrap
    if wrap then
      wraps = wraps or {}
      wraps[i] = wrap
    end
  end
  if not wraps then
    return nil
  end

  return function(packed)
    local rows = packed[1]
    for i = 1, count do
      local wrap = wraps[i]
      if wrap then
        rows[i] = wrap(rows[i])
      end
    end
    return pack_(rows)
  end
end

local function add_active(state, task)
  setv(state, task, 'status', 'active')
  pushv(state, state.active, task)
end

local complete_task

local function finish_group_lane(state, task, frame, outcome)
  local group = frame.group
  setv(state, group.lane_outcomes, frame.lane, outcome)
  bump(state, group, 'completed')
  setv(state, task, 'status', 'done')

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
  local parent = group.parent_task
  local activation_parts = {}
  for i = 1, group.count do
    activation_parts[i] = group.lane_outcomes[i].activation
  end
  setv(
    state,
    parent,
    'activation',
    Activation.child_array(group.activation, ACT.product_result, activation_parts)
  )
  setv(state, parent, 'status', 'active')
  return complete_task(state, parent, new_outcome(parent, pack_(rows), product_wrap(group.lane_outcomes)))
end

local function and_then_activation(frame, outcome)
  return Activation.child(frame.activation, ACT.and_then_result, outcome.activation)
end

complete_task = function(state, task, outcome)
  while true do
    local n = #task.frames
    if n == 0 then
      local root = task.root
      setv(state, root, 'done', true)
      setv(state, root, 'outcome', outcome)
      setv(state, task, 'status', 'done')
      return true
    end

    local frame = task.frames[n]
    setv(state, task.frames, n, nil)

    if frame.kind == 'map' then
      if outcome.wrap then
        error('transactional map attempted to consume a wrapped result', 0)
      end
      outcome = new_outcome(
        task,
        pack_(
          state.engine.runtime:_call_in_phase('map', 'callback_error', frame.fn, unpack_pack(outcome.pack))
        ),
        nil
      )
    elseif frame.kind == 'bind' then
      if outcome.wrap then
        error('and_then right-hand operation attempted to consume a wrapped result', 0)
      end
      local next_op = frame.q
      local input_pack = pack_(unpack_pack(outcome.pack))
      local next_activation = and_then_activation(frame, outcome)
      setv(state, task, 'guard_input_pack', input_pack)
      if next_op.kind == 'guard' then
        local request = task.root.request
        next_op = Activation.guard(state.engine, request, next_op, next_activation, true, input_pack)
        next_activation = Activation.child(next_activation, ACT.guard)
      end
      setv(state, task, 'expr', next_op)
      setv(state, task, 'activation', next_activation)
      add_active(state, task)
      return true
    elseif frame.kind == 'wrap' then
      outcome = new_outcome(task, outcome.pack, compose_wrap(outcome.wrap, frame.fn))
    elseif frame.kind == 'group_lane' then
      return finish_group_lane(state, task, frame, outcome)
    else
      error('unknown evaluator frame: ' .. tostring(frame.kind), 0)
    end
  end
end

local function add_root(state, request, required_intents)
  if not request or not request.pending or state.roots[request] then
    return request and request.pending or false
  end
  if not request.activation_root then
    request.activation_root = Activation.new_request(request.order)
  end

  local root = {
    serial = request.activation_root.id,
    request = request,
    expr = request.op,
    frames = {},
    scope_path = nil,
    status = 'active',
    activation = request.activation_root,
    required_intents = required_intents and copy_array(required_intents) or nil,
  }
  root.root = root
  root.segment = new_segment(state, root, nil)
  setv(state, state.roots, request, root)
  pushv(state, state.active, root)
  return true
end

local function start_product(state, task, op)
  local group = {
    parent_task = task,
    parent_segment = task.segment,
    mode = op.mode,
    count = #op.lanes,
    lane_segments = {},
    lane_outcomes = {},
    completed = 0,
    activation = task.activation,
  }
  setv(state, task, 'status', 'waiting_group')

  for i = 1, #op.lanes do
    local path = Activation.scope_child(task.scope_path, group, op.mode, i)
    local segment = new_segment(state, task.root, path, task.segment)
    group.lane_segments[i] = segment
    local activation = Activation.child(task.activation, ACT.product_lane, i)
    local child = {
      serial = activation.id,
      root = task.root,
      expr = op.lanes[i],
      frames = { { kind = 'group_lane', group = group, lane = i } },
      segment = segment,
      scope_path = path,
      status = 'active',
      activation = activation,
      guard_input_pack = task.guard_input_pack,
    }
    pushv(state, state.active, child)
  end
end

local function same_root_compatible(a, b)
  return Activation.relation(a.root, a.scope_path, b.root, b.scope_path) == 'interacting'
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
  if a.root ~= b.root then
    return true
  end
  return same_root_compatible(a, b)
end

local function root_requires(root, intent)
  for i = 1, #(root and root.required_intents or EMPTY) do
    if root.required_intents[i] == intent then
      return true
    end
  end
  return false
end

local function obligated_pair(a, b)
  return root_requires(a and a.root, b) or root_requires(b and b.root, a)
end

local function active_intents(state, out)
  out = out or {}
  local n = 0
  for i = 1, #(state.intents or EMPTY) do
    local intent = state.intents[i]
    if intent.active then
      n = n + 1
      out[n] = intent
    end
  end
  for i = #out, n + 1, -1 do
    out[i] = nil
  end
  return out
end

local function index_intent(state, intent)
  if intent.kind == 'exchange' then
    local buckets = ensure_table(state, 'exchange_buckets')
    local bucket = buckets[intent.resource]
    if not bucket then
      bucket = { put = {}, get = {} }
      setv(state, buckets, intent.resource, bucket)
    end
    pushv(state, bucket[intent.role], intent)
  elseif intent.kind == 'choice' then
    pushv(state, ensure_table(state, 'choices'), intent)
  elseif intent.kind == 'transition' then
    local rule = Operation.transition_behaviour(intent.spec)
    if rule.enumerable then
      pushv(state, ensure_table(state, 'witnesses'), intent)
    else
      local buckets = ensure_table(state, 'transition_buckets')
      local location = intent.spec.location
      local ids = buckets[location]
      if not ids then
        ids = {}
        setv(state, buckets, location, ids)
      end
      pushv(state, ids, intent)
    end
    if rule.accepts_supply then
      bump(state, state, 'accepts_supply_count')
    end
  end
end

local function remove_intents(state, intents)
  for i = 1, #intents do
    local intent = intents[i]
    if intent and intent.active then
      setv(state, intent, 'active', false)
      bump(state, state, 'active_intent_count', -1)
      if intent.kind == 'transition' and Operation.transition_behaviour(intent.spec).accepts_supply then
        bump(state, state, 'accepts_supply_count', -1)
      end
    end
  end
end

local function result_pack(leaf, value)
  return Operation.result_pack(leaf, value)
end

local function block_intent(state, task, occurrence, observed_version)
  local leaf = occurrence.spec
  local intents = ensure_table(state, 'intents')
  local serial = #intents + 1
  setv(state, task, 'status', 'blocked')
  local intent = {}
  intent.serial, intent.kind = serial, leaf_kind(leaf)
  intent.task, intent.root, intent.request, intent.spec = task, task.root, task.root.request, leaf
  intent.payload, intent.activation = occurrence.arg, task.activation
  intent.resource, intent.role, intent.value = leaf.resource, leaf.role, occurrence.arg
  intent.scope_path = task.scope_path
  intent.active = true
  intent.interest = type(leaf.interest) == 'function' and leaf.interest(state.engine.runtime, leaf)
    or leaf.interest
  local check = leaf.absence_check
  intent.absence_check = type(check) == 'function' and { validate = check } or check
  intent.observed_version = observed_version
  pushv(state, intents, intent)
  bump(state, state, 'active_intent_count')
  index_intent(state, intent)
end
local function block_choice(state, task, expr)
  local intents = ensure_table(state, 'intents')
  local serial = #intents + 1
  local intent = {
    serial = serial,
    kind = 'choice',
    task = task,
    root = task.root,
    request = task.root.request,
    expr = expr,
    order = choice_indices(
      state.engine,
      task,
      task.activation.id,
      #(expr.choices or {}),
      state.choice_generation
    ),
    activation = task.activation,
    scope_path = task.scope_path,
    required_intents = task.required_intents,
    active = true,
  }
  setv(state, task, 'status', 'blocked')
  pushv(state, intents, intent)
  bump(state, state, 'active_intent_count')
  index_intent(state, intent)
  return true
end

local function match_intents(state, a, b)
  if not a or not b or not a.active or not b.active then
    return false
  end
  local satisfy_a = root_requires(a.root, b)
  local satisfy_b = root_requires(b.root, a)
  remove_intents(state, { a, b })
  if satisfy_a then
    setv(state, a.root, 'required_intents', nil)
  end
  if satisfy_b then
    setv(state, b.root, 'required_intents', nil)
  end
  local put = a.role == 'put' and a or b
  local get = a.role == 'get' and a or b
  local put_task = put.task
  local get_task = get.task
  local left, right = a.activation, b.activation
  if Activation.less(right, left) then
    left, right = right, left
  end
  setv(
    state,
    put_task,
    'activation',
    Activation.child(put_task.activation, ACT.exchange, left, right, a.resource)
  )
  setv(
    state,
    get_task,
    'activation',
    Activation.child(get_task.activation, ACT.exchange, left, right, a.resource)
  )
  if not complete_task(state, put_task, new_outcome(put_task, PACK_TRUE)) then
    return false
  end
  if not complete_task(state, get_task, new_outcome(get_task, pack_(put.value))) then
    return false
  end
  return true
end

local function transition_context(state)
  local context = state.transition_context
  if not context then
    context = {}
    context.runtime = state.engine.runtime
    context.now = function()
      return state.engine.runtime:now()
    end
    state.transition_context = context
  end
  return context
end

local function transition_ready(state, leaf, value, payload)
  return Operation.transition_ready(leaf, value, transition_context(state), payload)
end

local function transition_outcome(state, leaf, value, phase, payload)
  return Operation.transition_cursor(leaf, value, transition_context(state), phase, payload):next()
end

local function stage_outcome(state, task, leaf, outcome)
  local patch
  if outcome.writes then
    if outcome.machine then
      bump(state, state, 'next_machine_serial')
    end
    patch = Operation.transition_patch(leaf, outcome, state.next_machine_serial)
  end
  if patch then
    Journal.stage(task.segment, leaf.location, patch)
  else
    Journal.observe(task.segment, leaf.location)
  end
end

local function transition_activation(selected)
  local keys = {}
  for i = 1, #selected do
    local intent, leaf = selected[i], selected[i].spec
    keys[#keys + 1] = intent.activation
    keys[#keys + 1] = leaf.location
    keys[#keys + 1] = intent.observed_version or leaf.location.version or 0
  end
  return keys
end

local function finish_transitions(state, selected, resolved)
  local facts = transition_activation(selected)
  remove_intents(state, selected)
  for i = 1, #resolved do
    local row = resolved[i]
    setv(state, row.task, 'activation', Activation.child_array(row.task.activation, ACT.transition, facts))
    if not complete_task(state, row.task, new_outcome(row.task, row.result)) then
      return false
    end
  end
  return true
end

local function selected_intents(intents)
  local selected = {}
  for i = 1, #intents do
    local intent = intents[i]
    if intent and intent.active then
      selected[#selected + 1] = intent
    end
  end
  table.sort(selected, function(a, b)
    return a.serial < b.serial
  end)
  return selected
end

local function resolve_serial_transitions(state, selected)
  table.sort(selected, function(left, right)
    local a, b =
      Operation.transition_behaviour(left.spec).order, Operation.transition_behaviour(right.spec).order
    return a ~= b and a < b or a == b and (left.serial or 0) < (right.serial or 0)
  end)
  local resolved = {}
  for i = 1, #selected do
    local intent, leaf = selected[i], selected[i].spec
    local task, rule = intent.task, Operation.transition_behaviour(leaf)
    local value = Journal.project_machine(task, leaf.location, function(candidate)
      return transition_ready(state, leaf, candidate, intent.payload)
    end, rule.accepts_supply)
    local outcome = transition_outcome(state, leaf, value, nil, intent.payload)
    if not outcome then
      return false
    end
    stage_outcome(state, task, leaf, outcome)
    resolved[#resolved + 1] = { task = task, result = outcome.result }
  end
  return finish_transitions(state, selected, resolved)
end

local function resolve_transitions(state, intents)
  local selected = selected_intents(intents)
  if #selected == 0 then
    return false
  end
  if Operation.transition_behaviour(selected[1].spec).serial then
    return resolve_serial_transitions(state, selected)
  end
  local resolved, remaining = {}, copy_array(selected)
  while #remaining > 0 do
    local chosen_index, chosen_outcome, chosen_task
    for i = 1, #remaining do
      local intent, leaf = remaining[i], remaining[i].spec
      local task = intent.task
      local value = Journal.project(task, leaf.location, leaf.orientation)
      if value ~= nil then
        local outcome = transition_outcome(state, leaf, value, nil, intent.payload)
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
    stage_outcome(state, chosen_task, intent.spec, chosen_outcome)
    resolved[#resolved + 1] = { task = chosen_task, result = chosen_outcome.result }
    table.remove(remaining, chosen_index)
  end
  return finish_transitions(state, selected, resolved)
end

local function witness_cursor(state, intent)
  local leaf, task, rule = intent.spec, intent.task, Operation.transition_behaviour(intent.spec)
  local value = Journal.project_machine(task, leaf.location, function(candidate)
    return transition_ready(state, leaf, candidate, intent.payload)
  end, rule.accepts_supply, state.journal)
  return Operation.transition_cursor(leaf, value, transition_context(state), nil, intent.payload)
end

local function resolve_witness(state, intent, outcome, alternative_index)
  if not intent or not outcome then
    return false
  end
  local task = intent.task
  stage_outcome(state, task, intent.spec, outcome)
  remove_intents(state, { intent })
  setv(
    state,
    task,
    'activation',
    Activation.child(
      task.activation,
      ACT.witness,
      intent.activation,
      intent.spec.location,
      intent.observed_version or intent.spec.location.version or 0,
      alternative_index or 1
    )
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

local function resolve_claim_set(state, group, intents)
  local selected = {}
  for i = 1, #intents do
    selected[intents[i]] = true
  end
  for i = 1, #(group.intents or {}) do
    local intent = group.intents[i]
    local rule = intent and Operation.transition_behaviour(intent.spec)
    if rule and rule.serial and rule.total then
      selected[intent] = true
    end
  end
  local expanded = {}
  for intent in pairs(selected) do
    expanded[#expanded + 1] = intent
  end
  table.sort(expanded, function(a, b)
    return a.serial < b.serial
  end)
  return resolve_transitions(state, expanded)
end

local function final_candidate(state)
  local participant_count, participant_1, participant_2, participants = 0
  for request in pairs(state.roots) do
    participant_count = participant_count + 1
    if participant_count == 1 then
      participant_1 = request
    elseif participant_count == 2 then
      participant_2 = request
    else
      participants = participants or { participant_1, participant_2 }
      participants[participant_count] = request
    end
  end
  local function earlier(a, b)
    return a.order < b.order
  end
  if participants then
    table.sort(participants, earlier)
  elseif participant_count == 2 and earlier(participant_2, participant_1) then
    participant_1, participant_2 = participant_2, participant_1
  end

  local observations, writes, collect_err
  if participant_count == 1 then
    local root = state.roots[participant_1]
    if not root.done or (state.active_intent_count or 0) > 0 then
      return nil
    end
    observations = next(state.journal.observed) and state.journal.observed or nil
    writes = next(root.segment.delta) and root.segment.delta or nil
  else
    local root_views = {}
    local function add_participant(index, request)
      local root = state.roots[request]
      if not root.done then
        return false
      end
      root_views[index] = root.segment
      return true
    end
    if participants then
      for i = 1, participant_count do
        if not add_participant(i, participants[i]) then
          return nil
        end
      end
    else
      if participant_1 and not add_participant(1, participant_1) then
        return nil
      end
      if participant_2 and not add_participant(2, participant_2) then
        return nil
      end
    end
    if (state.active_intent_count or 0) > 0 then
      return nil
    end
    observations, writes, collect_err = state.journal:collect_candidate(root_views)
    if collect_err then
      return nil
    end
  end
  observations = observations and next(observations) and observations or nil
  writes = writes and next(writes) and writes or nil
  for loc, patch in pairs(writes or EMPTY) do
    if loc.domain == 'counter' then
      local final, owner = Algebra.apply(loc, loc.value, patch), loc.owner
      if owner.min ~= nil and final < owner.min then
        return nil
      end
      if owner.max ~= nil and final > owner.max then
        return nil
      end
    end
  end

  local candidate = Candidate.new({
    participant_count = participant_count,
    participant_1 = participant_1,
    participant_2 = participant_2,
    participants = participants,
    observations = observations,
    writes = writes,
    effects = state.effects and #state.effects > 0 and copy_array(state.effects) or nil,
    absence_gate = state.absence_gate,
  })
  if participants then
    candidate.outcomes = {}
    for i = 1, participant_count do
      local request = participants[i]
      candidate.outcomes[request] = state.roots[request].outcome
    end
  else
    candidate.outcome_1 = participant_1 and state.roots[participant_1].outcome or nil
    candidate.outcome_2 = participant_2 and state.roots[participant_2].outcome or nil
  end
  if candidate.absence_gate then
    Proof.ensure(state.engine)
    Proof.acknowledge(state.engine, state)
    candidate.absence_gate.snapshot = Proof.capture(state.engine, state, candidate.absence_gate)
  end
  if not candidate:prepare(state.engine) then
    return nil
  end
  return candidate
end

local function execute_leaf(state, task, occurrence)
  local leaf = occurrence.spec
  if not leaf or leaf._fibers_leaf_spec ~= true then
    error('primitive payload is not an executable leaf specification', 0)
  end

  local kind = leaf_kind(leaf)
  if kind == 'exchange' then
    block_intent(state, task, occurrence)
    return true
  end

  if kind == 'clock_now' then
    local root = task.root
    local request = root and root.request
    local value = Activation.clock(state.engine, request, occurrence, task.activation)
    advance_activation(state, task, leaf)
    return complete_task(state, task, new_outcome(task, Operation.result_pack(leaf, value)))
  end

  if kind == 'observe' then
    local resource = leaf.resource
    local view = task.segment
    local value = leaf.observation.collect(resource, function(location)
      return Journal.read(view, location)
    end)
    advance_activation(state, task, leaf, resource.version or 0)
    return complete_task(state, task, new_outcome(task, Operation.result_pack(leaf, value)))
  end

  local view = task.segment
  local loc = leaf.location

  if kind == 'version_wait' then
    local version = occurrence.arg
    if loc.version ~= version then
      Journal.observe(view, loc)
      advance_activation(state, task, leaf, loc.version or 0)
      return complete_task(state, task, new_outcome(task, pack_(Journal.read(view, loc), loc.version)))
    end
    block_intent(state, task, occurrence, loc.version)
    return true
  end

  if kind == 'read' then
    advance_activation(state, task, leaf, loc.version or 0)
    return complete_task(state, task, new_outcome(task, result_pack(leaf, Journal.read(view, loc))))
  end

  if kind == 'patch' then
    local patch = occurrence.arg
    Journal.stage(view, loc, patch)
    advance_activation(state, task, leaf, loc.version or 0)
    return complete_task(state, task, new_outcome(task, result_pack(leaf, Journal.read(view, loc))))
  end

  if kind == 'transition' then
    local rule = Operation.transition_behaviour(leaf)
    if rule.eager then
      local value = Journal.read(view, loc)
      local outcome = transition_outcome(state, leaf, value, 'eager', occurrence.arg)
      if outcome then
        stage_outcome(state, task, leaf, outcome)
        advance_activation(state, task, leaf, loc.version or 0)
        return complete_task(state, task, new_outcome(task, outcome.result))
      end
    end
    block_intent(state, task, occurrence)
    return true
  end

  error('unknown leaf kind: ' .. tostring(kind), 0)
end

local function frontier_supply_score(frontier, intents)
  if not frontier then
    return 0
  end
  local score = 0
  for i = 1, #(intents or EMPTY) do
    local demand = intents[i]
    if demand.kind == 'exchange' then
      local roles = frontier.exchanges and frontier.exchanges[demand.resource]
      local latent = frontier.latent_exchanges and frontier.latent_exchanges[demand.resource]
      local opposite = demand.role == 'put' and 'get' or demand.role == 'get' and 'put' or nil
      if opposite and ((roles and roles[opposite]) or (latent and latent[opposite])) then
        score = score + 1
      end
    end
  end
  return score
end

local function supplier_score(state, request, intents)
  local frontier = request._proof
  -- Dirty invalidates a retained proof or suspended search, not the frontier's
  -- value as positive supplier evidence. A stale positive hint may recruit an
  -- extra root, which execution then rechecks; suppressing it can hide a
  -- continuation which static active shape has not yet reached.
  local exact = frontier and frontier_supply_score(frontier, intents) or 0
  local metadata = request.metadata or Operation.shape(request.op)
  request.metadata = metadata
  local structural, certainty, reason = Operation.supply_score(Operation.active_shape(metadata), intents)
  if exact > 0 then
    return exact * 1000 + structural
  end
  -- Metadata is derived mechanically from the actual immutable Op graph.  Dynamic
  -- guards remain conservative in Operation.supply_score; no user declaration is
  -- trusted.  Observed frontiers improve ordering without becoming proof.
  return structural
end

local function has_supplier(state, intents)
  for i = 1, #(state.all_requests or EMPTY) do
    local request = state.all_requests[i]
    if request.pending and not state.roots[request] then
      local score = supplier_score(state, request, intents)
      if score > 0 then
        return true
      end
    end
  end
  return false
end

local function terminal_refutation(state)
  return Proof.from_intents(active_intents(state))
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
  elseif kind == 'map' then
    collect_defeat_effects(expr.p, out)
  elseif kind == 'and_then' then
    -- Only the prefix is entered before sequencing reaches the right-hand side.
    collect_defeat_effects(expr.p, out)
  end
  return out
end

local function table_empty(value)
  return value == nil or next(value) == nil
end

local function exchange_partner_available(state, task, resource, role)
  local synthetic = {
    kind = 'exchange',
    resource = resource,
    role = role,
    root = task.root,
    request = task.root.request,
    scope_path = task.scope_path,
  }
  local bucket = state.exchange_buckets and state.exchange_buckets[resource]
  local opposite = role == 'put' and 'get' or 'put'
  for i = 1, #(bucket and bucket[opposite] or EMPTY) do
    local current = bucket[opposite][i]
    if current and current.active and intents_compatible(synthetic, current) then
      return true
    end
  end
  return has_supplier(state, { synthetic })
end

local function alternative_rank(state, intent, choice_index, rank_partners)
  local task = intent.task
  local alternative = intent.expr.choices[choice_index]
  local metadata = Operation.active_shape(Operation.shape(alternative))
  local score = 0

  local required = intent.required_intents
  if required and #required > 0 then
    local supplied, certainty = Operation.supply_score(metadata, required)
    if supplied > 0 then
      score = score + 1000 + supplied * 20
      if certainty == Operation.SUPPLY_EXACT then
        score = score + 5
      end
    elseif metadata.dynamic then
      score = score + 500
    else
      score = score - 1000
    end
  end

  -- For a statically exchange-only alternative, prefer worlds whose every
  -- externally required role still has a current or recruitable partner.  This
  -- is ordering only: alternatives are never removed, so incomplete metadata
  -- cannot establish absence or change the admitted worlds.
  if
    rank_partners
    and not metadata.dynamic
    and not metadata.external
    and table_empty(metadata.locations)
    and table_empty(metadata.resources)
    and not table_empty(metadata.exchanges)
  then
    local needed, available = 0, 0
    for resource, roles in pairs(metadata.exchanges) do
      if not (roles.put and roles.get) then
        for role in pairs(roles) do
          needed = needed + 1
          if exchange_partner_available(state, task, resource, role) then
            available = available + 1
          end
        end
      end
    end
    score = score + available * 25
    if available < needed then
      score = score - (needed - available) * 200
    end
  end

  return score
end

local function single_exchange_shape(metadata)
  metadata = Operation.active_shape(metadata)
  if
    metadata.dynamic
    or metadata.external
    or next(metadata.locations or EMPTY)
    or next(metadata.resources or EMPTY)
  then
    return nil
  end
  local found_resource, found_role
  for resource, roles in pairs(metadata.exchanges or EMPTY) do
    for role, enabled in pairs(roles) do
      if enabled then
        if found_resource ~= nil then
          return nil
        end
        found_resource, found_role = resource, role
      end
    end
  end
  return found_resource, found_role
end

-- Find one structurally viable all-different assignment for unresolved choices.
-- This is an ordering propagator only: every alternative remains in the normal
-- exhaustive order after the preferred edge, and failure never proves Retry.
local function supplier_matching_preferences(state, choices)
  if #choices < 3 then
    return nil
  end

  local suppliers = {}
  for i = 1, #(state.all_requests or EMPTY) do
    local request = state.all_requests[i]
    if request.pending and not state.roots[request] then
      local metadata = request.metadata or Operation.shape(request.op)
      request.metadata = metadata
      local resource, role = single_exchange_shape(metadata)
      if resource and (role == 'put' or role == 'get') then
        local by_role = suppliers[resource]
        if not by_role then
          by_role = { put = {}, get = {} }
          suppliers[resource] = by_role
        end
        by_role[role][#by_role[role] + 1] = request
      end
    end
  end

  local rows = {}
  for i = 1, #choices do
    local choice, edges = choices[i], {}
    for position = 1, #(choice.order or EMPTY) do
      local choice_index = choice.order[position]
      local metadata = Operation.shape(choice.expr.choices[choice_index])
      local resource, role = single_exchange_shape(metadata)
      local opposite = role == 'put' and 'get' or role == 'get' and 'put' or nil
      local ids = resource and opposite and suppliers[resource] and suppliers[resource][opposite] or EMPTY
      for j = 1, #ids do
        edges[#edges + 1] = { supplier = ids[j], choice_index = choice_index, order = position }
      end
    end
    if #edges == 0 then
      return nil
    end
    table.sort(edges, function(a, b)
      if a.order ~= b.order then
        return a.order < b.order
      end
      return a.supplier.order < b.supplier.order
    end)
    rows[#rows + 1] = { choice = choice, edges = edges }
  end
  table.sort(rows, function(a, b)
    if #a.edges ~= #b.edges then
      return #a.edges < #b.edges
    end
    return a.choice.serial < b.choice.serial
  end)

  local matching = bipartite_matching(rows, nil, 'edges', 'supplier')
  if not matching then
    return nil
  end
  local selected = {}
  for i = 1, #rows do
    local row, edge = rows[i], matching[rows[i]]
    selected[row.choice] = edge.choice_index
  end
  return selected
end

local function ranked_choice_order(state, intent, rank_partners, preferred_index)
  if not intent.required_intents and not rank_partners then
    return intent.order
  end
  local order = copy_array(intent.order)
  local base_position = {}
  for i = 1, #order do
    base_position[order[i]] = i
  end
  local scores = {}
  for i = 1, #order do
    local choice_index = order[i]
    scores[choice_index] = alternative_rank(state, intent, choice_index, rank_partners)
    if preferred_index == choice_index then
      scores[choice_index] = scores[choice_index] + 10000
    end
  end
  table.sort(order, function(a, b)
    local sa, sb = scores[a], scores[b]
    if sa ~= sb then
      return sa > sb
    end
    return base_position[a] < base_position[b]
  end)
  return order
end

local function resolve_choice(state, intent, choice_index)
  if not intent then
    return false
  end
  local expr, task = intent.expr, intent.task
  if not choice_index or not task then
    return false
  end
  remove_intents(state, { intent })
  local effects = ensure_table(state, 'effects')
  for i = 1, #(expr.choices or {}) do
    if i ~= choice_index then
      local defeats = collect_defeat_effects(expr.choices[i])
      for j = 1, #defeats do
        pushv(state, effects, defeats[j])
      end
    end
  end
  setv(state, task, 'expr', expr.choices[choice_index])
  setv(state, task, 'activation', Activation.child(intent.activation, ACT.choice, choice_index))
  add_active(state, task)
  return true
end

local search

local function hard_stop(state, reason)
  state.engine._last_search_unknown_reason = reason
  if state.resumable then
    state.hard_limit = true
    state.unknown_reason = reason
  end
  return false
end

local function await_search_budget(state)
  if not state.resumable then
    return
  end
  while state.work_remaining <= 0 do
    state:yield_search('search_quantum')
  end
end

local function note_search_step(state)
  local engine = state.engine
  local resumable = state.resumable
  await_search_budget(state)

  while engine._cycle_budget and not engine:charge('work') do
    if not resumable then
      return false
    end
    state:yield_search(engine._last_search_unknown_reason or 'cycle_work_limit')
  end
  if resumable then
    state.work_remaining = state.work_remaining - 1
  end

  state.steps = state.steps + 1
  if engine.search_total_limit and state.steps > engine.search_total_limit then
    return hard_stop(state, 'search_total_limit')
  end
  if engine.search_depth_limit and state.search_depth > engine.search_depth_limit then
    return hard_stop(state, 'search_depth_limit')
  end
  if engine.search_trail_limit and state.journal:size() > engine.search_trail_limit then
    return hard_stop(state, 'search_trail_limit')
  end

  return true
end

local function merge_refutation(current, next_ref)
  return Proof.merge(current, next_ref)
end

local function explore(state, apply)
  local mark = state.journal:mark()
  state.search_depth = state.search_depth + 1
  if not apply() then
    state.search_depth = state.search_depth - 1
    state.journal:rollback(mark)
    return nil, Proof.new(), false
  end
  local candidate, refutation, unknown = search(state)
  state.search_depth = state.search_depth - 1
  if candidate then
    return candidate, refutation, unknown, mark
  end
  state.journal:rollback(mark)
  return nil, refutation, unknown
end

local function propagate(state, fn)
  local mark = state.journal:mark()
  local ok = fn()
  if ok then
    state.journal:accept(mark)
    return true
  end
  state.journal:rollback(mark)
  return false
end

local function prefer(state, task, expr)
  local mark = state.journal:mark()
  state.search_depth = state.search_depth + 1
  setv(state, task, 'expr', expr.p)
  setv(state, task, 'activation', Activation.child(task.activation, ACT.preferred))
  add_active(state, task)
  local candidate, preferred_refutation, unknown = search(state)
  state.search_depth = state.search_depth - 1
  if candidate then
    return candidate
  end
  state.journal:rollback(mark)
  if unknown then
    return nil, preferred_refutation, true
  end

  local previous_gate = state.absence_gate
  local gate = Proof.merge(Proof.copy(previous_gate), preferred_refutation)
  gate.membership_sensitive = previous_gate and previous_gate.membership_sensitive or false
  Proof.mark_absence_gate_frontier(gate)
  -- A proof may stop at a deferred choice before branch-local frontiers are
  -- materialised.  The immutable preferred shape is used only to decide whether
  -- newly admitted participants could invalidate this candidate; it never proves
  -- absence.
  local preferred_shape = Operation.shape(expr.p)
  if
    preferred_shape.dynamic
    or next(preferred_shape.exchanges or EMPTY) ~= nil
    or next(preferred_shape.locations or EMPTY) ~= nil
    or next(preferred_shape.resources or EMPTY) ~= nil
  then
    gate.membership_sensitive = true
  end
  setv(state, state, 'absence_gate', gate)
  setv(state, task, 'expr', expr.q)
  setv(
    state,
    task,
    'activation',
    Activation.child_array(task.activation, ACT.fallback, Proof.gate_facts(preferred_refutation))
  )
  add_active(state, task)
  local fallback, fallback_refutation, fallback_unknown = search(state)
  if fallback then
    return fallback, fallback_refutation, fallback_unknown
  end
  -- The preferred branch has been discarded as an active wait, but a newly
  -- admitted compatible participant must invalidate the Retry and cause the
  -- operation to be reconsidered. Preserve only that latent membership
  -- frontier; state versions, external interests and checks remain those of
  -- the fallback branch.
  return nil, Proof.merge_latent_frontier(fallback_refutation, preferred_refutation), fallback_unknown
end

local function reduce_one(state, task)
  local expr = task.expr
  local kind = expr.kind
  if kind == 'always' then
    return complete_task(state, task, new_outcome(task, expr.vals)) and 'progress' or 'conflict'
  elseif kind == 'guard' then
    local parent = task.activation
    local request = task.root.request
    local residual = Activation.guard(state.engine, request, expr, parent, true, task.guard_input_pack)
    setv(state, task, 'expr', residual)
    setv(state, task, 'activation', Activation.child(parent, ACT.guard))
    add_active(state, task)
    return 'progress'
  elseif kind == 'map' then
    pushv(state, task.frames, { kind = 'map', fn = expr.fn })
    setv(state, task, 'expr', expr.p)
    setv(state, task, 'activation', Activation.child(task.activation, ACT.map))
    add_active(state, task)
    return 'progress'
  elseif kind == 'and_then' then
    pushv(state, task.frames, { kind = 'bind', q = expr.q, activation = task.activation })
    setv(state, task, 'expr', expr.p)
    setv(state, task, 'activation', Activation.child(task.activation, ACT.and_then_prefix))
    add_active(state, task)
    return 'progress'
  elseif kind == 'annotated' then
    local parent = task.activation
    if expr.post then
      pushv(state, task.frames, { kind = 'wrap', fn = expr.post })
    end
    setv(state, task, 'expr', expr.p)
    setv(state, task, 'activation', Activation.child(parent, ACT.annotated))
    add_active(state, task)
    return 'progress'
  elseif kind == 'consequence' then
    pushv(state, ensure_table(state, 'effects'), expr.effect)
    return complete_task(state, task, new_outcome(task, pack_())) and 'progress' or 'conflict'
  elseif kind == 'primitive' then
    return execute_leaf(state, task, expr) and 'progress' or 'conflict'
  elseif kind == 'product' then
    start_product(state, task, expr)
    return 'progress'
  elseif kind == 'choice' then
    return block_choice(state, task, expr) and 'progress' or 'conflict'
  elseif kind == 'or_else' then
    return 'prefer'
  end
  error('unsupported Op kind: ' .. tostring(kind), 0)
end

local function recruit_supplier(state, refutation)
  local intents = active_intents(state)
  for i = 1, #(state.all_requests or EMPTY) do
    local request = state.all_requests[i]
    if request.pending and not state.roots[request] and supplier_score(state, request, intents) > 0 then
      local candidate, ref, unknown = explore(state, function()
        return add_root(state, request, intents)
      end)
      if candidate then
        return candidate
      end
      refutation = merge_refutation(refutation, ref)
      if unknown then
        return nil, refutation, true
      end
    end
  end
  return nil, merge_refutation(refutation, terminal_refutation(state)), false
end

local PROPAGATED = {}

local function resolve_frontier(state)
  local intents = active_intents(state)

  if #intents == 1 and intents[1].kind == 'exchange' then
    return recruit_supplier(state)
  end

  -- The overwhelmingly common rendezvous case is a unique pair.  Resolve it
  -- directly rather than constructing a general frontier and a speculative
  -- checkpoint for a decision which has no alternative.
  if #intents == 2 and intents_compatible(intents[1], intents[2]) then
    local selected = intents[1].serial < intents[2].serial and intents[1] or intents[2]
    if obligated_pair(intents[1], intents[2]) or not has_supplier(state, { selected }) then
      if match_intents(state, intents[1], intents[2]) then
        return PROPAGATED
      end
      return nil, terminal_refutation(state), false
    end
  end

  local exchange_only = #intents > 0
  for i = 1, #intents do
    if intents[i].kind ~= 'exchange' then
      exchange_only = false
      break
    end
  end
  local closed_exchange = exchange_only and not has_supplier(state, intents)
  local frontier = analyse_frontier(state, intents_compatible, closed_exchange)
  local exchange = frontier.exchange

  if closed_exchange then
    if not exchange.balanced or exchange.zero_domains > 0 then
      return nil, terminal_refutation(state), false
    end
    if exchange.selected and exchange.selected_degree == 1 and #exchange.partners == 1 then
      if match_intents(state, exchange.selected, exchange.partners[1]) then
        return PROPAGATED
      end
      return nil, terminal_refutation(state), false
    end
  end

  local refutation
  if closed_exchange then
    local complete_matching = exchange.matching
    if complete_matching == false then
      return nil, terminal_refutation(state), false
    end
    if complete_matching then
      local candidate, matching_refutation, matching_unknown = explore(state, function()
        for i = 1, #complete_matching do
          local pair = complete_matching[i]
          if not match_intents(state, pair[1], pair[2]) then
            return false
          end
        end
        return true
      end)
      if candidate then
        return candidate
      end
      refutation = merge_refutation(refutation, matching_refutation)
      if matching_unknown then
        return nil, refutation, true
      end
    end
  end
  for i = 1, #exchange.partners do
    local partner = exchange.partners[i]
    local candidate, ref, unknown = explore(state, function()
      return match_intents(state, exchange.selected, partner)
    end)
    if candidate then
      return candidate
    end
    refutation = merge_refutation(refutation, ref)
    if unknown then
      return nil, refutation, true
    end
  end

  for i = 1, #frontier.witnesses do
    local intent = frontier.witnesses[i]
    local cursor = witness_cursor(state, intent)
    local alternative_index = 0
    while true do
      local outcome = cursor:next()
      if outcome == nil then
        break
      end
      alternative_index = alternative_index + 1
      local candidate, ref, unknown = explore(state, function()
        return resolve_witness(state, intent, outcome, alternative_index)
      end)
      if candidate then
        return candidate
      end
      refutation = merge_refutation(refutation, ref)
      if unknown then
        return nil, refutation, true
      end
    end
  end

  for i = 1, #frontier.claims do
    local group = frontier.claims[i]
    local all_machine = group.all_machine
    local accepts_supply = group.accepts_supply
    if all_machine and not accepts_supply then
      if
        propagate(state, function()
          return resolve_claim_set(state, group, group.intents)
        end)
      then
        return PROPAGATED
      end
      return nil, merge_refutation(refutation, terminal_refutation(state)), false
    else
      if all_machine and #group.intents > 1 then
        local candidate, ref, unknown = explore(state, function()
          return resolve_claim_set(state, group, group.intents)
        end)
        if candidate then
          return candidate
        end
        refutation = merge_refutation(refutation, ref)
        if unknown then
          return nil, refutation, true
        end
      end
      for j = 1, #group.intents do
        local intent = group.intents[j]
        local candidate, ref, unknown = explore(state, function()
          return resolve_claim_set(state, group, { intent })
        end)
        if candidate then
          return candidate
        end
        refutation = merge_refutation(refutation, ref)
        if unknown then
          return nil, refutation, true
        end
      end
    end
  end

  local obligated_supplier_present = false
  if exchange.selected then
    for i = 1, #exchange.partners do
      if obligated_pair(exchange.selected, exchange.partners[i]) then
        obligated_supplier_present = true
        break
      end
    end
  end
  if frontier.accepts_participant_supply and not obligated_supplier_present then
    local candidate, supplied_refutation, supplied_unknown = recruit_supplier(state, refutation)
    if candidate or supplied_unknown then
      return candidate, supplied_refutation, supplied_unknown
    end
    refutation = supplied_refutation
  end

  local choice = frontier.choices and frontier.choices[1]
  if choice then
    local preferences = supplier_matching_preferences(state, frontier.choices)
    local order = ranked_choice_order(
      state,
      choice,
      #(frontier.choices or EMPTY) > 2,
      preferences and preferences[choice]
    )
    for i = 1, #order do
      local choice_index = order[i]
      local candidate, branch_refutation, unknown = explore(state, function()
        return resolve_choice(state, choice, choice_index)
      end)
      if candidate then
        return candidate
      end
      refutation = merge_refutation(refutation, branch_refutation)
      if unknown then
        return nil, refutation, true
      end
    end
  end

  return nil, merge_refutation(refutation, terminal_refutation(state)), false
end

search = function(state)
  if not note_search_step(state) then
    return nil, Proof.new(), true
  end

  while true do
    while state.active_head <= #state.active do
      local task = state.active[state.active_head]
      setv(state, state, 'active_head', state.active_head + 1)
      if task and task.status == 'active' then
        local result = reduce_one(state, task)
        if result == 'conflict' then
          return nil, terminal_refutation(state), false
        elseif result == 'prefer' then
          return prefer(state, task, task.expr)
        end
      end
    end

    local candidate = final_candidate(state)
    if candidate then
      return candidate
    end
    local result, refutation, unknown = resolve_frontier(state)
    if result ~= PROPAGATED then
      return result, refutation, unknown
    end
  end
end

local function publish_frontiers(state, result)
  -- During an unbounded driver pass, a completed Retry while more ready fibres
  -- are still being admitted is provisional scheduler knowledge. Persisting it
  -- would build and tear down an index for the common two-party rendezvous path.
  -- Bounded sessions still publish because their retained coroutine requires a
  -- versioned snapshot across host turns.
  if result and result.retry and state.provisional_admission and not state.resumable then
    return nil
  end
  Proof.ensure(state.engine)
  local published = Proof.frontiers(state.intents, state.roots, result and result.certificate)
  for request, frontier in pairs(published) do
    Proof.publish(state.engine, request, frontier)
  end
  local snapshot = Proof.capture(state.engine, state, result and result.certificate, published)
  if state.resumable then
    state.frontier_snapshot = snapshot
  end
  local focus = published[state.focus]
  if focus and result and result.retry then
    focus.retry = true
    focus.snapshot = snapshot
    focus.certificate = result.certificate or focus.certificate
  end
  return snapshot
end

local function new_state(engine, requests, focus, component, provisional_admission)
  if not requests[focus] then
    return nil
  end
  local instrumentation = engine.instrumentation
  local journal = Journal.new()
  local state = setmetatable({
    engine = engine,
    all_requests = engine.pending,
    focus = focus,
    choice_generation = component and component.order_generation or nil,
    provisional_admission = provisional_admission == true,
    active = {},
    active_head = 1,
    roots = {},
    next_machine_serial = 0,
    active_intent_count = 0,
    accepts_supply_count = 0,
    search_depth = 0,
    steps = 0,
    journal = journal,
  }, Search)
  if instrumentation then
    instrumentation:begin_search(state, {
      focus = focus,
      pending = map_count(requests),
      total_pending = #engine.pending,
      component_size = component and component.size or map_count(requests),
    })
  end
  add_root(state, focus)
  return state
end

local function finish_profile(state, candidate, outcome)
  local instrumentation = state.engine.instrumentation
  if not instrumentation then
    return
  end
  instrumentation:finish_search(state, outcome, { search_steps = state.steps })
end

local function new_search(engine, requests, focus, component, provisional_admission)
  local state = new_state(engine, requests, focus, component, provisional_admission)
  if not state then
    return nil
  end
  state.resumable, state.hard_limit, state.work_remaining = true, false, 0
  if engine.instrumentation then
    engine.instrumentation:pause_search(state)
  end
  state.thread = coroutine.create(function()
    return search(state)
  end)
  return state
end

function Search:yield_search(reason)
  self.unknown_reason = reason or 'search_quantum'
  return coroutine.yield(terminal_refutation(self), self.unknown_reason)
end

function Search:advance(max_work)
  if not self.thread then
    error('search is closed', 2)
  end
  self.work_remaining = math.max(0, math.floor(max_work or self.engine.search_limit))
  self.unknown_reason = nil
  local instrumentation = self.engine.instrumentation
  if instrumentation then
    instrumentation:resume_search(self)
  end
  local resumed = { coroutine.resume(self.thread) }
  if instrumentation then
    instrumentation:pause_search(self)
  end
  if not resumed[1] then
    error(resumed[2], 0)
  end

  if coroutine.status(self.thread) ~= 'dead' then
    publish_frontiers(self, { unknown = true })
    if instrumentation then
      instrumentation:inc('retained_search_suspensions')
    end
    self.unknown_reason = resumed[3] or self.unknown_reason or 'search_quantum'
    return nil, resumed[2], true
  end

  local candidate, certificate, unknown = resumed[2], resumed[3], resumed[4]
  if candidate then
    candidate._search = self
    self.candidate = candidate
    finish_profile(self, candidate, 'found')
    return candidate, certificate, false
  end
  publish_frontiers(self, { retry = not unknown, unknown = unknown, certificate = certificate })
  finish_profile(self, nil, unknown and 'unknown' or 'retry')
  return nil, certificate, unknown == true
end

function Search:discard(reason)
  if not self.thread then
    return
  end
  if coroutine.status(self.thread) ~= 'dead' then
    finish_profile(self, nil, reason or 'invalidated')
  end
  self.thread = nil
  if self.journal and self.journal.reset then
    self.journal:reset()
  end
  if self.candidate then
    self.candidate._search = nil
  end
  self.candidate, self.frontier_snapshot = nil, nil
end

function M.search(engine, requests, focus, search_limit, component, provisional_admission)
  if search_limit == nil and not engine.explicit_search_limit then
    local state = new_state(engine, requests, focus, component, provisional_admission)
    if not state then
      return nil
    end
    local candidate, refutation, unknown = search(state)
    if not candidate then
      publish_frontiers(state, { retry = not unknown, certificate = refutation })
    end
    finish_profile(state, candidate, candidate and 'found' or (unknown and 'unknown' or 'retry'))
    return candidate, refutation, unknown
  end

  local state = new_search(engine, requests, focus, component, provisional_admission)
  if not state then
    return nil
  end
  local candidate, refutation, unknown = state:advance(search_limit or engine.search_limit)
  return candidate, refutation, unknown, state
end

return M

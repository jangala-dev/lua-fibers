-- A deliberately small, copy-on-branch exhaustive reference evaluator for Fibers.
--
-- This is an oracle, not a runtime.  It evaluates one finite, closed operation
-- and returns every coherent world.  There is no scheduler, retained search,
-- symmetry pruning, journal, host I/O or hidden participant recruitment.
-- Potential participants must be written explicitly with Op.together.

local Reference = {}
local Op = {}
Op.__index = Op
Reference.Op = Op

local unpack_ = table.unpack or unpack

local function pack(...)
  return { n = select('#', ...), ... }
end

local function unpack_pack(xs)
  return unpack_(xs, 1, xs.n or #xs)
end

local function copy_array(xs)
  local out = {}
  for i = 1, #(xs or {}) do
    out[i] = xs[i]
  end
  return out
end

local function node(kind, fields)
  fields = fields or {}
  fields.kind = kind
  return setmetatable(fields, Op)
end

local function is_op(value)
  return type(value) == 'table' and getmetatable(value) == Op
end

local function expect_op(value, label)
  if not is_op(value) then
    error(label .. ' expects an Op', 3)
  end
  return value
end

function Op.always(...)
  return node('always', { values = pack(...) })
end

function Op.never()
  return node('choice', { choices = {} })
end

function Op.choice(...)
  local choices = {}
  for i = 1, select('#', ...) do
    local choice = expect_op(select(i, ...), 'choice')
    if choice.kind == 'choice' then
      for j = 1, #choice.choices do
        choices[#choices + 1] = choice.choices[j]
      end
    else
      choices[#choices + 1] = choice
    end
  end
  if #choices == 0 then
    return Op.never()
  end
  if #choices == 1 then
    return choices[1]
  end
  return node('choice', { choices = choices })
end

function Op.guard(fn)
  if type(fn) ~= 'function' then
    error('guard expects a function', 2)
  end
  return node('guard', { fn = fn })
end

function Op:map(fn)
  if type(fn) ~= 'function' then
    error('map expects a function', 2)
  end
  return node('map', { p = self, fn = fn })
end

function Op:and_then(q)
  return node('and_then', { p = self, q = expect_op(q, 'and_then') })
end

function Op:or_else(q)
  return node('or_else', { p = self, q = expect_op(q, 'or_else') })
end

local function product(mode, ...)
  local lanes = {}
  for i = 1, select('#', ...) do
    lanes[i] = expect_op(select(i, ...), mode)
  end
  if #lanes == 0 then
    return Op.always({ _rows = true })
  end
  return node('product', { mode = mode, lanes = lanes })
end

function Op.each(...)
  return product('independent', ...)
end

function Op.together(...)
  return product('interacting', ...)
end

-- The small model has two location algebras.  They are enough to expose the
-- important difference between independent constraint and positive supply.
function Op.read(location)
  return node('read', { location = assert(location, 'read requires a location') })
end

function Op.set(location, value)
  return node('set', { location = assert(location, 'set requires a location'), value = value })
end

function Op.add(location, delta)
  if type(delta) ~= 'number' then
    error('add expects a numeric delta', 2)
  end
  return node('add', { location = assert(location, 'add requires a location'), delta = delta })
end

function Op.take(location, amount)
  amount = amount or 1
  if type(amount) ~= 'number' or amount < 0 then
    error('take expects a non-negative amount', 2)
  end
  return node('transition', {
    location = assert(location, 'take requires a location'),
    demand = 'up',
    decide = function(value)
      if value < amount then
        return nil
      end
      return { patch = { kind = 'add', delta = -amount }, values = pack(true) }
    end,
  })
end

function Op.at_least(location, threshold)
  if type(threshold) ~= 'number' then
    error('at_least expects a number', 2)
  end
  return node('transition', {
    location = assert(location, 'at_least requires a location'),
    demand = 'up',
    decide = function(value)
      if value < threshold then
        return nil
      end
      return { values = pack(value) }
    end,
  })
end

function Op.get(resource)
  return node('exchange', { resource = assert(resource, 'get requires a resource'), role = 'get' })
end

function Op.put(resource, value)
  return node(
    'exchange',
    { resource = assert(resource, 'put requires a resource'), role = 'put', value = value }
  )
end

function Op.emit(effect)
  return node('emit', { effect = effect })
end

local function clone_patch(patch)
  if not patch then
    return nil
  end
  if patch.kind == 'add' then
    return { kind = 'add', delta = patch.delta }
  end
  return { kind = 'replace', value = patch.value }
end

local function location_kind(state, name)
  local location = state.locations[name]
  if not location then
    error('unknown reference location: ' .. tostring(name), 0)
  end
  return location.kind
end

local function apply_patch(value, patch)
  if not patch then
    return value
  end
  if patch.kind == 'add' then
    return value + patch.delta
  end
  return patch.value
end

local function stage_patch(kind, previous, patch)
  if patch.kind ~= kind then
    return nil, 'wrong-algebra'
  end
  if kind == 'add' then
    return { kind = 'add', delta = (previous and previous.delta or 0) + patch.delta }
  end
  return { kind = 'replace', value = patch.value }
end

local function join_patch(kind, left, right)
  if not left then
    return clone_patch(right)
  end
  if not right then
    return clone_patch(left)
  end
  if kind == 'add' then
    return { kind = 'add', delta = left.delta + right.delta }
  end
  if left.value ~= right.value then
    return nil, 'replace-conflict'
  end
  return clone_patch(left)
end

local function constraint_patch(patch, demand)
  if not patch then
    return nil
  end
  if patch.kind == 'replace' or demand == nil then
    return clone_patch(patch)
  end
  if demand == 'up' and patch.delta < 0 then
    return clone_patch(patch)
  end
  if demand == 'down' and patch.delta > 0 then
    return clone_patch(patch)
  end
  return nil
end

local function relation(left, right)
  if left == right then
    return 'same'
  end
  local a, b = left, right
  local da, db = a and a.depth or 0, b and b.depth or 0
  while da > db do
    a, da = a.parent, da - 1
  end
  while db > da do
    b, db = b.parent, db - 1
  end
  if a == b then
    return (left and left.depth or 0) > (right and right.depth or 0) and 'ancestor' or 'descendant'
  end
  while a and b and a.parent ~= b.parent do
    a, b = a.parent, b.parent
  end
  if not a or not b or a.group ~= b.group or a.lane == b.lane then
    return 'unrelated'
  end
  return a.mode == 'interacting' and 'interacting' or 'independent'
end

local function child_path(parent, group, mode, lane)
  return {
    parent = parent,
    depth = parent and parent.depth + 1 or 1,
    group = group,
    mode = mode,
    lane = lane,
  }
end

local function clone_state(state)
  local out = {
    locations = state.locations,
    tasks = {},
    segments = {},
    groups = {},
    root_task = state.root_task,
    next_task = state.next_task,
    next_segment = state.next_segment,
    next_group = state.next_group,
    effects = copy_array(state.effects),
    trace = copy_array(state.trace),
  }
  for id, segment in pairs(state.segments) do
    local delta = {}
    for name, patch in pairs(segment.delta) do
      delta[name] = clone_patch(patch)
    end
    out.segments[id] = {
      parent = segment.parent,
      path = segment.path,
      delta = delta,
      retired = segment.retired,
    }
  end
  for id, group in pairs(state.groups) do
    local rows = {}
    for lane, values in pairs(group.rows) do
      rows[lane] = values
    end
    out.groups[id] = {
      parent_task = group.parent_task,
      parent_segment = group.parent_segment,
      mode = group.mode,
      count = group.count,
      completed = group.completed,
      child_segments = copy_array(group.child_segments),
      rows = rows,
    }
  end
  for id, task in pairs(state.tasks) do
    local frames = {}
    for i = 1, #task.frames do
      local frame = task.frames[i]
      frames[i] = { kind = frame.kind, fn = frame.fn, q = frame.q, group = frame.group, lane = frame.lane }
    end
    out.tasks[id] = {
      expr = task.expr,
      frames = frames,
      status = task.status,
      segment = task.segment,
      path = task.path,
      result = task.result,
      guard_input = task.guard_input,
    }
  end
  return out
end

local function own_value(state, segment_id, name)
  local segment = state.segments[segment_id]
  local value
  if segment.parent then
    value = own_value(state, segment.parent, name)
  else
    value = state.locations[name].value
  end
  return apply_patch(value, segment.delta[name])
end

local function projected_value(state, task, name, demand)
  local own = state.segments[task.segment]
  local value = own_value(state, task.segment, name)
  local combined
  local kind = location_kind(state, name)
  for id, segment in pairs(state.segments) do
    local patch = segment.delta[name]
    if id ~= task.segment and not segment.retired and patch then
      local rel = relation(task.path, segment.path)
      local visible
      if rel == 'interacting' then
        visible = patch
      elseif rel == 'independent' then
        visible = constraint_patch(patch, demand)
      end
      if visible then
        local err
        combined, err = join_patch(kind, combined, visible)
        if not combined then
          return nil, err
        end
      end
    end
  end
  return apply_patch(value, combined)
end

local function stage(state, segment_id, name, patch)
  local segment = state.segments[segment_id]
  local kind = location_kind(state, name)
  local summary, err = stage_patch(kind, segment.delta[name], patch)
  if not summary then
    return false, err
  end
  segment.delta[name] = summary
  return true
end

local function rows_pack(rows, count)
  local value = { _rows = true }
  for i = 1, count do
    value[i] = rows[i]
  end
  return pack(value)
end

local complete_task

local function join_group(state, group)
  local merged = {}
  for i = 1, group.count do
    local segment = state.segments[group.child_segments[i]]
    for name, patch in pairs(segment.delta) do
      local next_patch, err = join_patch(location_kind(state, name), merged[name], patch)
      if not next_patch then
        return false, err
      end
      merged[name] = next_patch
    end
  end
  for name, patch in pairs(merged) do
    local ok, err = stage(state, group.parent_segment, name, patch)
    if not ok then
      return false, err
    end
  end
  for i = 1, group.count do
    state.segments[group.child_segments[i]].retired = true
  end
  return true
end

complete_task = function(state, task_id, values)
  local task = state.tasks[task_id]
  while true do
    local frame = task.frames[#task.frames]
    if not frame then
      task.status, task.result = 'done', values
      return true
    end
    task.frames[#task.frames] = nil
    if frame.kind == 'map' then
      values = pack(frame.fn(unpack_pack(values)))
    elseif frame.kind == 'bind' then
      task.expr, task.guard_input, task.status = frame.q, values, 'active'
      return true
    elseif frame.kind == 'lane' then
      local group = state.groups[frame.group]
      task.status = 'done'
      group.rows[frame.lane] = values
      group.completed = group.completed + 1
      if group.completed < group.count then
        return true
      end
      local ok = join_group(state, group)
      if not ok then
        return false
      end
      local parent = state.tasks[group.parent_task]
      parent.status = 'active'
      return complete_task(state, group.parent_task, rows_pack(group.rows, group.count))
    else
      error('unknown reference frame: ' .. tostring(frame.kind), 0)
    end
  end
end

local function start_product(state, task_id, expr)
  local task = state.tasks[task_id]
  local group_id = state.next_group + 1
  state.next_group = group_id
  local group = {
    parent_task = task_id,
    parent_segment = task.segment,
    mode = expr.mode,
    count = #expr.lanes,
    completed = 0,
    child_segments = {},
    rows = {},
  }
  state.groups[group_id] = group
  task.status = 'waiting_group'
  for i = 1, #expr.lanes do
    local segment_id = state.next_segment + 1
    state.next_segment = segment_id
    local path = child_path(task.path, group_id, expr.mode, i)
    state.segments[segment_id] = { parent = task.segment, path = path, delta = {}, retired = false }
    group.child_segments[i] = segment_id
    local child_id = state.next_task + 1
    state.next_task = child_id
    state.tasks[child_id] = {
      expr = expr.lanes[i],
      frames = { { kind = 'lane', group = group_id, lane = i } },
      status = 'active',
      segment = segment_id,
      path = path,
      guard_input = task.guard_input,
    }
  end
end

local function active_task(state)
  for id = 1, state.next_task do
    local task = state.tasks[id]
    if task and task.status == 'active' then
      return id, task
    end
  end
end

local function final_world(state)
  local root = state.tasks[state.root_task]
  if not root or root.status ~= 'done' then
    return nil
  end
  local root_segment = state.segments[root.segment]
  local locations, writes = {}, {}
  local names = {}
  for name in pairs(state.locations) do
    names[#names + 1] = name
  end
  table.sort(names)
  for i = 1, #names do
    local name = names[i]
    locations[name] = own_value(state, root.segment, name)
    local patch = root_segment.delta[name]
    if patch then
      writes[name] = clone_patch(patch)
    end
  end
  return {
    result = root.result,
    locations = locations,
    writes = writes,
    effects = copy_array(state.effects),
    trace = copy_array(state.trace),
  }
end

local function exchange_compatible(a, b)
  return a.expr.resource == b.expr.resource
    and a.expr.role ~= b.expr.role
    and relation(a.path, b.path) == 'interacting'
end

local function resolve_exchange(state, left_id, right_id)
  local left, right = state.tasks[left_id], state.tasks[right_id]
  local put = left.expr.role == 'put' and left or right
  local put_id = left.expr.role == 'put' and left_id or right_id
  local get_id = left.expr.role == 'get' and left_id or right_id
  left.status, right.status = 'active', 'active'
  state.trace[#state.trace + 1] = 'exchange:' .. tostring(put.expr.resource)
  if not complete_task(state, put_id, pack(true)) then
    return false
  end
  return complete_task(state, get_id, pack(put.expr.value))
end

local function resolve_transition(state, task_id, outcome)
  local task = state.tasks[task_id]
  if outcome.patch then
    local ok = stage(state, task.segment, task.expr.location, outcome.patch)
    if not ok then
      return false
    end
  end
  task.status = 'active'
  state.trace[#state.trace + 1] = 'transition:' .. tostring(task.expr.location)
  return complete_task(state, task_id, outcome.values or pack())
end

local function scalar_key(value)
  local kind = type(value)
  if kind == 'nil' then
    return 'n'
  end
  if kind == 'boolean' then
    return value and 'b1' or 'b0'
  end
  if kind == 'number' then
    return 'd' .. string.format('%.17g', value)
  end
  if kind == 'string' then
    return 's' .. #value .. ':' .. value
  end
  return kind .. ':' .. tostring(value)
end

local function encode(value, seen)
  if type(value) ~= 'table' then
    return scalar_key(value)
  end
  seen = seen or {}
  if seen[value] then
    return '<cycle>'
  end
  seen[value] = true
  local keys = {}
  for key in pairs(value) do
    keys[#keys + 1] = key
  end
  table.sort(keys, function(a, b)
    return scalar_key(a) < scalar_key(b)
  end)
  local out = { '{' }
  for i = 1, #keys do
    local key = keys[i]
    out[#out + 1] = encode(key, seen) .. '=' .. encode(value[key], seen) .. ';'
  end
  out[#out + 1] = '}'
  seen[value] = nil
  return table.concat(out)
end

local search

local function search_branches(states, context)
  local hits, unknown = {}, false
  for i = 1, #states do
    local branch_hits, branch_unknown = search(states[i], context)
    for j = 1, #branch_hits do
      hits[#hits + 1] = branch_hits[j]
    end
    unknown = unknown or branch_unknown
  end
  return hits, unknown
end

search = function(state, context)
  context.steps = context.steps + 1
  if context.steps > context.max_steps then
    return {}, true
  end

  while true do
    local task_id, task = active_task(state)
    if not task then
      break
    end
    local expr = task.expr

    if expr.kind == 'always' then
      if not complete_task(state, task_id, expr.values) then
        return {}, false
      end
    elseif expr.kind == 'guard' then
      local values = task.guard_input or pack()
      local residual = expr.fn(unpack_pack(values))
      if not is_op(residual) then
        error('guard callback must return a reference Op', 0)
      end
      task.expr = residual
    elseif expr.kind == 'map' then
      task.frames[#task.frames + 1] = { kind = 'map', fn = expr.fn }
      task.expr = expr.p
    elseif expr.kind == 'and_then' then
      task.frames[#task.frames + 1] = { kind = 'bind', q = expr.q }
      task.expr = expr.p
    elseif expr.kind == 'choice' then
      local branches = {}
      for i = 1, #expr.choices do
        local branch = clone_state(state)
        branch.tasks[task_id].expr = expr.choices[i]
        branches[#branches + 1] = branch
      end
      return search_branches(branches, context)
    elseif expr.kind == 'or_else' then
      local preferred = clone_state(state)
      preferred.tasks[task_id].expr = expr.p
      local hits, unknown = search(preferred, context)
      if #hits > 0 or unknown then
        return hits, unknown
      end
      local fallback = clone_state(state)
      fallback.tasks[task_id].expr = expr.q
      fallback.trace[#fallback.trace + 1] = 'fallback'
      return search(fallback, context)
    elseif expr.kind == 'product' then
      start_product(state, task_id, expr)
    elseif expr.kind == 'read' then
      if not complete_task(state, task_id, pack(own_value(state, task.segment, expr.location))) then
        return {}, false
      end
    elseif expr.kind == 'set' then
      if not stage(state, task.segment, expr.location, { kind = 'replace', value = expr.value }) then
        return {}, false
      end
      if not complete_task(state, task_id, pack(true)) then
        return {}, false
      end
    elseif expr.kind == 'add' then
      if not stage(state, task.segment, expr.location, { kind = 'add', delta = expr.delta }) then
        return {}, false
      end
      if not complete_task(state, task_id, pack(true)) then
        return {}, false
      end
    elseif expr.kind == 'emit' then
      state.effects[#state.effects + 1] = expr.effect
      if not complete_task(state, task_id, pack()) then
        return {}, false
      end
    elseif expr.kind == 'transition' or expr.kind == 'exchange' then
      task.status = 'blocked'
    else
      error('unsupported reference Op kind: ' .. tostring(expr.kind), 0)
    end
  end

  local world = final_world(state)
  if world then
    return { world }, false
  end

  local branches = {}
  for id = 1, state.next_task do
    local task = state.tasks[id]
    if task and task.status == 'blocked' and task.expr.kind == 'transition' then
      local value = projected_value(state, task, task.expr.location, task.expr.demand)
      if value ~= nil then
        local outcome = task.expr.decide(value)
        if outcome then
          local branch = clone_state(state)
          if resolve_transition(branch, id, outcome) then
            branches[#branches + 1] = branch
          end
        end
      end
    end
  end

  for left_id = 1, state.next_task do
    local left = state.tasks[left_id]
    if left and left.status == 'blocked' and left.expr.kind == 'exchange' then
      for right_id = left_id + 1, state.next_task do
        local right = state.tasks[right_id]
        if
          right
          and right.status == 'blocked'
          and right.expr.kind == 'exchange'
          and exchange_compatible(left, right)
        then
          local branch = clone_state(state)
          if resolve_exchange(branch, left_id, right_id) then
            branches[#branches + 1] = branch
          end
        end
      end
    end
  end

  if #branches == 0 then
    return {}, false
  end
  return search_branches(branches, context)
end

local function normalise_locations(input)
  local out = {}
  for name, value in pairs(input or {}) do
    if type(value) == 'table' and (value.kind == 'add' or value.kind == 'replace') then
      out[name] = { kind = value.kind, value = value.value }
    elseif type(value) == 'number' then
      out[name] = { kind = 'add', value = value }
    else
      out[name] = { kind = 'replace', value = value }
    end
  end
  return out
end

function Reference.evaluate(op, options)
  expect_op(op, 'evaluate')
  options = options or {}
  local state = {
    locations = normalise_locations(options.locations),
    tasks = {},
    segments = {},
    groups = {},
    root_task = 1,
    next_task = 1,
    next_segment = 1,
    next_group = 0,
    effects = {},
    trace = {},
  }
  state.segments[1] = { parent = nil, path = nil, delta = {}, retired = false }
  state.tasks[1] = { expr = op, frames = {}, status = 'active', segment = 1, path = nil }

  local context = { steps = 0, max_steps = options.max_steps or 100000 }
  local worlds, unknown = search(state, context)
  local unique, deduped = {}, {}
  for i = 1, #worlds do
    local key = encode({
      result = worlds[i].result,
      locations = worlds[i].locations,
      writes = worlds[i].writes,
      effects = worlds[i].effects,
    })
    if not unique[key] then
      unique[key] = true
      deduped[#deduped + 1] = worlds[i]
    end
  end
  table.sort(deduped, function(a, b)
    return encode(a) < encode(b)
  end)

  if unknown then
    return { tag = 'Unknown', reason = 'work-limit', worlds = deduped, steps = context.steps }
  end
  if #deduped > 0 then
    return { tag = 'Hit', worlds = deduped, steps = context.steps }
  end
  return { tag = 'Retry', steps = context.steps }
end

function Reference.unpack(values)
  return unpack_pack(values)
end

function Reference.add_location(value)
  return { kind = 'add', value = value }
end

function Reference.replace_location(value)
  return { kind = 'replace', value = value }
end

return Reference

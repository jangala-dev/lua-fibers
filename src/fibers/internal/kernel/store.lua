-- Common transactional substrate for the evaluator.
--
-- The substrate is deliberately closed and compact:
--
--   * versioned locations;
--   * fixed patch algebras (replace, add, presence, finite_map and machine);
--   * forked speculative views;
--   * provenance-aware projection for partial options;
--   * generic validation and commit.
--
-- Facility modules construct locations and options.  They do not define
-- search, fallback, validation, product visibility or commit semantics.

local Op = require('fibers.op')

local M = {}

M.ABSENT = setmetatable({}, {
  __tostring = function()
    return '<absent>'
  end,
})

local next_location_id = 0

local function copy_map(xs)
  local out = {}
  for k, v in pairs(xs or {}) do
    out[k] = v
  end
  return out
end

function M.new_location(opts)
  opts = opts or {}
  next_location_id = next_location_id + 1
  local loc = {
    id = next_location_id,
    name = opts.name or ('location-' .. tostring(next_location_id)),
    merge = assert(opts.merge, 'location merge algebra is required'),
    domain = opts.domain or 'plain',
    value = opts.value,
    version = opts.version or 0,
    owner = opts.owner,
    key = opts.key,
    apply = opts.apply,
    clone_value = opts.clone_value,
    put_equal = opts.put_equal == true,
    remove_idempotent = opts.remove_idempotent ~= false,
  }
  loc.tags = {
    stock = {},
    present = {},
    absent = {},
  }
  return loc
end

function M.clone_patch(p)
  if not p then
    return nil
  end
  if p.kind == 'replace' then
    return { kind = 'replace', value = p.value }
  end
  if p.kind == 'add' then
    return { kind = 'add', delta = p.delta }
  end
  if p.kind == 'machine' then
    local steps = {}
    for i = 1, #(p.steps or {}) do
      local st = p.steps[i]
      steps[i] = { serial = st.serial, value = st.value }
    end
    return { kind = 'machine', steps = steps }
  end
  if p.kind == 'presence' or p.kind == 'finite_map' then
    local ops = {}
    for i = 1, #(p.ops or {}) do
      local op = p.ops[i]
      ops[i] = { op = op.op, key = op.key, value = op.value, policy = op.policy }
    end
    return { kind = p.kind, ops = ops }
  end
  error('unknown patch kind: ' .. tostring(p.kind), 2)
end

function M.clone_view(view)
  local cells, delta = {}, {}
  for loc, rec in pairs(view.cells or {}) do
    cells[loc] = { value = rec.value, version = rec.version }
  end
  for loc, patch in pairs(view.delta or {}) do
    delta[loc] = M.clone_patch(patch)
  end
  return {
    id = view.id,
    parent = view.parent,
    cells = cells,
    delta = delta,
    root_id = view.root_id,
    scope_path = view.scope_path,
    merged = view.merged == true,
  }
end

function M.new_view(root_id, scope_path, source, id, view)
  view = view or {}
  view.id = id
  view.parent = source
  view.cells = view.cells or {}
  view.delta = view.delta or {}
  view.root_id = root_id
  view.scope_path = scope_path
  view.merged = false
  return view
end

function M.find_cell(view, loc)
  local current = view
  while current do
    local rec = current.cells[loc]
    if rec then
      return rec, current
    end
    current = current.parent
  end
  return nil
end

function M.cell(view, loc, trail)
  local rec = M.find_cell(view, loc)
  if not rec then
    rec = { value = loc.value, version = loc.version or 0 }
    if trail then
      trail:set(view.cells, loc, rec)
    else
      view.cells[loc] = rec
    end
  end
  return rec
end

local function writable_cell(view, loc, trail)
  local rec = view.cells[loc]
  if rec then
    return rec
  end

  local inherited = view.parent and M.find_cell(view.parent, loc) or nil
  if inherited then
    rec = { value = inherited.value, version = inherited.version }
  else
    rec = { value = loc.value, version = loc.version or 0 }
  end
  if trail then
    trail:set(view.cells, loc, rec)
  else
    view.cells[loc] = rec
  end
  return rec
end

function M.read(view, loc, trail)
  return M.cell(view, loc, trail).value
end

local function clone_map_value(loc, value)
  local out = {}
  for k, v in pairs(value or {}) do
    out[k] = loc.clone_value and loc.clone_value(v) or v
  end
  return out
end

function M.apply_patch_value(loc, value, patch)
  if patch.kind == 'replace' then
    return patch.value
  end
  if patch.kind == 'add' then
    return value + patch.delta
  end
  if patch.kind == 'presence' then
    for i = 1, #(patch.ops or {}) do
      local op = patch.ops[i]
      if op.op == 'put' then
        value = op.value
      elseif op.op == 'remove' or op.op == 'take' then
        value = M.ABSENT
      else
        error('unknown presence operation: ' .. tostring(op.op), 2)
      end
    end
    return value
  end
  if patch.kind == 'machine' then
    local steps = patch.steps or {}
    if #steps == 0 then
      return value
    end
    return steps[#steps].value
  end
  if patch.kind == 'finite_map' then
    local out = clone_map_value(loc, value)
    for i = 1, #(patch.ops or {}) do
      local op = patch.ops[i]
      if op.op == 'put' then
        out[op.key] = loc.clone_value and loc.clone_value(op.value) or op.value
      elseif op.op == 'remove' or op.op == 'take' then
        out[op.key] = nil
      else
        error('unknown finite-map operation: ' .. tostring(op.op), 2)
      end
    end
    return out
  end
  error('unknown patch kind: ' .. tostring(patch.kind), 2)
end

local function set_field(trail, target, key, value)
  if trail then
    trail:set(target, key, value)
  else
    target[key] = value
  end
end

local function push_value(trail, target, value)
  if trail then
    trail:push(target, value)
  else
    target[#target + 1] = value
  end
end

function M.stage(view, loc, patch, trail)
  local rec = writable_cell(view, loc, trail)
  local old = view.delta[loc]

  if loc.merge == 'replace' then
    if patch.kind ~= 'replace' then
      error('replace location requires replace patch', 2)
    end
    set_field(trail, rec, 'value', patch.value)
    set_field(trail, view.delta, loc, { kind = 'replace', value = patch.value })
    return true
  end

  if loc.merge == 'add' then
    if patch.kind ~= 'add' then
      error('add location requires add patch', 2)
    end
    set_field(trail, rec, 'value', rec.value + patch.delta)
    if old then
      set_field(trail, old, 'delta', old.delta + patch.delta)
    else
      set_field(trail, view.delta, loc, { kind = 'add', delta = patch.delta })
    end
    return true
  end

  if loc.merge == 'machine' then
    if patch.kind ~= 'machine' then
      error('machine location requires machine patch', 2)
    end
    if old then
      for i = 1, #(patch.steps or {}) do
        local step = patch.steps[i]
        local previous = old.steps[#old.steps]
        if previous and previous.serial >= step.serial then
          error('machine steps must be staged in increasing serial order', 2)
        end
        push_value(trail, old.steps, step)
      end
    else
      set_field(trail, view.delta, loc, M.clone_patch(patch))
    end
    set_field(trail, rec, 'value', M.apply_patch_value(loc, rec.value, patch))
    return true
  end

  if loc.merge == 'presence' or loc.merge == 'finite_map' then
    local expected = loc.merge
    if patch.kind ~= expected then
      error(expected .. ' location requires ' .. expected .. ' patch', 2)
    end
    set_field(trail, rec, 'value', M.apply_patch_value(loc, rec.value, patch))
    if old then
      for i = 1, #(patch.ops or {}) do
        push_value(trail, old.ops, patch.ops[i])
      end
    else
      set_field(trail, view.delta, loc, M.clone_patch(patch))
    end
    return true
  end

  error('unknown location algebra: ' .. tostring(loc.merge), 2)
end

function M.merge_parallel(loc, left, right, composition)
  if not left then
    return M.clone_patch(right)
  end
  if not right then
    return M.clone_patch(left)
  end

  if loc.merge == 'add' then
    return { kind = 'add', delta = left.delta + right.delta }
  end

  if loc.merge == 'machine' then
    local steps = {}
    for i = 1, #(left.steps or {}) do
      steps[#steps + 1] = left.steps[i]
    end
    for i = 1, #(right.steps or {}) do
      steps[#steps + 1] = right.steps[i]
    end
    table.sort(steps, function(a, b)
      return a.serial < b.serial
    end)
    return { kind = 'machine', steps = steps }
  end

  if loc.merge == 'presence' then
    local function simple(p)
      if p.kind ~= 'presence' or #(p.ops or {}) ~= 1 then
        return nil
      end
      return p.ops[1]
    end
    local a, b = simple(left), simple(right)
    if a and b then
      if a.op == 'put' and b.op == 'put' then
        if a.value ~= b.value then
          return nil, 'presence-put-conflict'
        end
        return { kind = 'presence', ops = { { op = 'put', value = a.value } } }
      end
      if a.op == 'put' and b.op == 'take' then
        return { kind = 'presence', ops = { { op = 'put', value = a.value }, { op = 'take' } } }
      end
      if a.op == 'take' and b.op == 'put' then
        return { kind = 'presence', ops = { { op = 'put', value = b.value }, { op = 'take' } } }
      end
      if a.op == b.op and (a.op == 'remove') then
        return { kind = 'presence', ops = { { op = 'remove' } } }
      end
      return nil, 'presence-parallel-conflict'
    end
    return nil, 'presence-complex-parallel-conflict'
  end

  if loc.merge == 'finite_map' then
    local function by_key(p)
      local out = {}
      for i = 1, #(p.ops or {}) do
        local op = p.ops[i]
        local xs = out[op.key]
        if not xs then
          xs = {}
          out[op.key] = xs
        end
        xs[#xs + 1] = op
      end
      return out
    end
    local la, rb = by_key(left), by_key(right)
    local keys = {}
    for k in pairs(la) do
      keys[k] = true
    end
    for k in pairs(rb) do
      keys[k] = true
    end
    local ops = {}
    local function append(xs)
      for i = 1, #(xs or {}) do
        local op = xs[i]
        ops[#ops + 1] = { op = op.op, key = op.key, value = op.value, policy = op.policy }
      end
    end
    for k in pairs(keys) do
      local a, b = la[k], rb[k]
      if not a then
        append(b)
      elseif not b then
        append(a)
      elseif #a == 1 and #b == 1 then
        local x, y = a[1], b[1]
        if x.op == 'put' and y.op == 'put' then
          if loc.put_equal and x.value == y.value then
            append({ x })
          elseif
            (composition == 'interacting' or composition == 'external')
            and x.policy == 'overwrite'
            and y.policy == 'overwrite'
          then
            append({ y }) -- ordered interacting composition: later claim wins
          else
            return nil, 'finite-map-put-conflict'
          end
        elseif (x.op == 'put' and y.op == 'take') or (x.op == 'take' and y.op == 'put') then
          local put = x.op == 'put' and x or y
          append({ put, { op = 'take', key = k } })
        elseif x.op == 'remove' and y.op == 'remove' and loc.remove_idempotent then
          append({ x })
        else
          return nil, 'finite-map-parallel-conflict'
        end
      else
        return nil, 'finite-map-complex-parallel-conflict'
      end
    end
    return { kind = 'finite_map', ops = ops }
  end

  if loc.merge == 'replace' then
    if left.value ~= right.value then
      return nil, 'replace-conflict'
    end
    return { kind = 'replace', value = left.value }
  end

  return nil, 'unknown-location-algebra'
end

local function patch_orientation_component(loc, patch, direction)
  if not patch then
    return nil
  end
  if patch.kind == 'add' then
    local is_up = patch.delta > 0
    local is_down = patch.delta < 0
    if (direction == 'up' and is_up) or (direction == 'down' and is_down) then
      return M.clone_patch(patch)
    end
    return nil
  end
  if patch.kind == 'presence' or patch.kind == 'finite_map' then
    local ops = {}
    for i = 1, #(patch.ops or {}) do
      local op = patch.ops[i]
      local is_up = op.op == 'put'
      local is_down = op.op == 'remove' or op.op == 'take'
      if (direction == 'up' and is_up) or (direction == 'down' and is_down) then
        ops[#ops + 1] = { op = op.op, key = op.key, value = op.value, policy = op.policy }
      end
    end
    if #ops == 0 then
      return nil
    end
    return { kind = patch.kind, ops = ops }
  end
  return M.clone_patch(patch)
end

-- In an independent product lane, sibling changes which positively support a
-- partial demand are hidden, while changes which constrain it remain visible.
-- `orientation` says which direction of the location order supplies the claim:
-- `up` for stock/presence/selection, `down` for absence/compatibility.
function M.constraint_projection(loc, patch, orientation)
  if not orientation then
    return M.clone_patch(patch)
  end
  local constraining = orientation == 'up' and 'down' or 'up'
  return patch_orientation_component(loc, patch, constraining)
end

local function persistent_path_relation(path, other_path)
  if path == other_path then
    return 'same'
  end
  local a, b = path, other_path
  local da = a and a.depth or 0
  local db = b and b.depth or 0
  if da > db then
    for _ = 1, da - db do
      a = a.parent
    end
    if a == b then
      return 'ancestor'
    end
  elseif db > da then
    for _ = 1, db - da do
      b = b.parent
    end
    if a == b then
      return 'descendant'
    end
  end
  if a == b then
    return 'same'
  end
  while a and b and a.parent ~= b.parent do
    a, b = a.parent, b.parent
  end
  if not a or not b or a.group_id ~= b.group_id then
    return 'unrelated'
  end
  if a.lane == b.lane then
    return 'unrelated'
  end
  return a.mode == 'interacting' and 'interacting' or 'independent'
end

local function path_relation(root_id, path, other_root, other_path)
  if root_id ~= other_root then
    return 'external'
  end
  if (path and path._fibers_scope_path) or (other_path and other_path._fibers_scope_path) then
    return persistent_path_relation(path, other_path)
  end
  path, other_path = path or {}, other_path or {}
  local n = math.min(#path, #other_path)
  for i = 1, n do
    local a, b = path[i], other_path[i]
    if a.group_id ~= b.group_id then
      return 'unrelated'
    end
    if a.lane ~= b.lane then
      return a.mode == 'interacting' and 'interacting' or 'independent'
    end
  end
  if #other_path < #path then
    return 'ancestor'
  end
  if #other_path == #path then
    return 'same'
  end
  return 'descendant'
end

M.path_relation = path_relation

-- Project one location for a partial claim.  The task's own view already
-- contains committed state, outer sequential changes and changes earlier in
-- the same lane.  Parallel views contribute as follows:
--
--   external root          all patches are available;
--   interacting sibling   all patches are available;
--   independent sibling   constraining patches are visible, supplying
--                         patches are hidden.
--
-- Ancestor views are already represented in the task's snapshot.  Merged
-- child views are ignored because their patches have moved to the parent.
function M.project(state, task, loc, orientation, trail)
  local own = state.views[task.view_id]
  local value = M.read(own, loc, trail)
  local used = {}
  local combined = nil

  for view_id, view in pairs(state.views) do
    if view_id ~= task.view_id and not view.merged then
      local patch = view.delta[loc]
      if patch then
        local relation = path_relation(task.root_id, task.scope_path, view.root_id, view.scope_path)
        local include_patch = nil
        if relation == 'external' or relation == 'interacting' then
          include_patch = patch
        elseif relation == 'independent' then
          include_patch = M.constraint_projection(loc, patch, orientation)
        end
        if include_patch then
          combined = M.merge_parallel(
            loc,
            combined,
            include_patch,
            relation == 'interacting' and 'interacting'
              or relation == 'external' and 'external'
              or 'independent'
          )
          if not combined then
            return nil, nil, 'projection-conflict'
          end
          used[#used + 1] = view_id
        end
      end
    end
  end

  if combined then
    value = M.apply_patch_value(loc, value, combined)
  end
  return value, used
end

-- Project a serial state-machine location for a partial transition.  Full
-- sibling state is visible across interacting products and roots.  For an
-- independent sibling, only a transition which invalidates an already-ready
-- demand is visible; a transition which makes an unready demand ready is
-- positive supply and is hidden.
function M.project_machine(state, task, loc, succeeds, accepts_supply, trail)
  local own = state.views[task.view_id]
  local value = M.read(own, loc, trail)
  local steps = {}

  for view_id, view in pairs(state.views) do
    if view_id ~= task.view_id and not view.merged then
      local patch = view.delta[loc]
      if patch and patch.kind == 'machine' then
        local relation = path_relation(task.root_id, task.scope_path, view.root_id, view.scope_path)
        if relation == 'external' or relation == 'interacting' or relation == 'independent' then
          for i = 1, #(patch.steps or {}) do
            local st = patch.steps[i]
            steps[#steps + 1] = { serial = st.serial, value = st.value, relation = relation }
          end
        end
      end
    end
  end

  table.sort(steps, function(a, b)
    return a.serial < b.serial
  end)
  for i = 1, #steps do
    local st = steps[i]
    local supply_restricted = st.relation == 'independent' or not accepts_supply
    if supply_restricted then
      local before = succeeds and succeeds(value) or false
      local after = succeeds and succeeds(st.value) or false
      -- A restricted relation hides only positive supply. Neutral and
      -- constraining changes remain visible so compatible updates compose.
      if before or not after then
        value = st.value
      end
    else
      value = st.value
    end
  end
  return value
end

function M.merge_views(parent, children, mode, trail)
  local writes = {}

  for i = 1, #children do
    local child = children[i]
    for loc, rec in pairs(child.cells) do
      if not M.find_cell(parent, loc) then
        local observed = { value = rec.value, version = rec.version }
        if trail then
          trail:set(parent.cells, loc, observed)
        else
          parent.cells[loc] = observed
        end
      end
    end
    for loc, patch in pairs(child.delta) do
      local merged, err = M.merge_parallel(loc, writes[loc], patch, mode or 'independent')
      if not merged then
        return false, err
      end
      writes[loc] = merged
    end
  end

  for loc, patch in pairs(writes) do
    M.stage(parent, loc, patch, trail)
  end
  for i = 1, #children do
    if trail then
      trail:set(children[i], 'merged', true)
    else
      children[i].merged = true
    end
  end
  return true
end

function M.collect_candidate(root_views)
  local observations, writes
  for i = 1, #root_views do
    local view = root_views[i]
    for loc, rec in pairs(view.cells) do
      observations = observations or {}
      local old = observations[loc]
      if old ~= nil and old ~= rec.version then
        return nil, nil, 'observation-conflict'
      end
      observations[loc] = rec.version
    end
    for loc, patch in pairs(view.delta) do
      writes = writes or {}
      local merged, err = M.merge_parallel(loc, writes[loc], patch, 'external')
      if not merged then
        return nil, nil, err
      end
      writes[loc] = merged
    end
  end
  return observations, writes
end

function M.validate(observations)
  for loc, version in pairs(observations or {}) do
    if (loc.version or 0) ~= version then
      return false, 'stale-location'
    end
  end
  return true
end

function M.validate_view(view)
  for loc, rec in pairs((view and view.cells) or {}) do
    if (loc.version or 0) ~= rec.version then
      return false, 'stale-location'
    end
  end
  return true
end

function M.commit_view(view)
  for loc, patch in pairs((view and view.delta) or {}) do
    local new_value = M.apply_patch_value(loc, loc.value, patch)
    loc.value = new_value
    loc.version = (loc.version or 0) + 1
    if loc.apply then
      loc.apply(new_value, loc)
    end
  end
end

function M.commit(writes)
  for loc, patch in pairs(writes or {}) do
    local new_value = M.apply_patch_value(loc, loc.value, patch)
    loc.value = new_value
    loc.version = (loc.version or 0) + 1
    if loc.apply then
      loc.apply(new_value, loc)
    end
  end
end

function M.copy_scope_path(path)
  local out = {}
  for i = 1, #(path or {}) do
    local e = path[i]
    out[i] = { group_id = e.group_id, mode = e.mode, lane = e.lane }
  end
  return out
end

function M.copy_intent(x)
  local out = copy_map(x)
  out.scope_path = M.copy_scope_path(x.scope_path)
  return out
end

local pack_ = Op._pack

function M.result_pack(program, value, session)
  local function result(...)
    if session then
      return session:pack(...)
    end
    return pack_(...)
  end
  local kind = program.result_kind or 'constant'
  if kind == 'constant' then
    return result(program.result_value)
  end
  if kind == 'identity' then
    return result(value)
  end
  if kind == 'presence_bool' then
    return result(value ~= M.ABSENT)
  end
  if kind == 'presence_value' then
    if value == M.ABSENT or (program.nil_sentinel and value == program.nil_sentinel) then
      return result(nil)
    end
    return result(value)
  end
  if kind == 'index_entry' then
    if value == nil then
      return result(nil)
    end
    return result({ key = value.key, rank = value.rank, value = value.value, seq = value.seq })
  end
  if kind == 'map_value' then
    return result(value)
  end
  if kind == 'scalar_snapshot' then
    return result({ value = value, version = program.location.version })
  end
  if kind == 'counter_state' then
    local owner = program.owner
    return result({
      value = value,
      min = owner.min,
      max = owner.max,
      version = program.location.version,
    })
  end
  error('unknown programme result kind: ' .. tostring(kind), 0)
end

function M.predicate_holds(program, value)
  if program.predicate == 'present' then
    return value ~= M.ABSENT
  end
  if program.predicate == 'absent' then
    return value == M.ABSENT
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
    local ar, br = ae[program.rank_field or 'rank'], be[program.rank_field or 'rank']
    if ar == br then
      local as, bs = ae[program.seq_field or 'seq'] or 0, be[program.seq_field or 'seq'] or 0
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
  return program.order == 'max' and candidates[#candidates] or candidates[1]
end

local function modes_compatible(compat, a, b)
  if a == b then
    return true
  end
  local row = compat and compat[a]
  return row and row[b] == true
end

function M.evaluate_claim(program, value)
  local query = program.query
  if not query and program.kind == 'conditional_claim' then
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
    if not M.predicate_holds(query, value) then
      return nil
    end
  elseif query.kind == 'extreme' then
    witness = select_extreme(query, value)
    if not witness then
      return nil
    end
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
  if not transition and program.kind == 'conditional_claim' then
    transition = { kind = 'static', patch = program.claim_patch }
  end
  local patch
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
  local result_value = query.kind == 'extreme' and witness.entry or witness
  return { patch = patch, result = M.result_pack(program, result_value) }
end

return M

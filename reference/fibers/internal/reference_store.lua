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

local Algebra = require('fibers.internal.kernel.algebra')
local IR = require('fibers.internal.kernel.ir')

local M = {}

M.ABSENT = Algebra.ABSENT

local next_location_id = 0

local function sorted_ids(values)
  local out = {}
  for id in pairs(values or {}) do
    out[#out + 1] = id
  end
  table.sort(out)
  return out
end

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
    algebra = Algebra.get(assert(opts.algebra or opts.merge, 'location algebra is required')),
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

M.clone_patch = Algebra.clone

function M.clone_segment(view)
  local cells, delta = {}, {}
  for loc, rec in pairs(view.values or {}) do
    cells[loc] = { value = rec.value, version = rec.version }
  end
  for loc, patch in pairs(view.delta or {}) do
    delta[loc] = M.clone_patch(patch)
  end
  return {
    id = view.id,
    parent = view.parent,
    values = cells,
    delta = delta,
    root_id = view.root_id,
    scope_path = view.scope_path,
    retired = view.retired == true,
  }
end

function M.new_segment(root_id, scope_path, source, id, view)
  view = view or {}
  view.id = id
  view.parent = source
  view.values = view.values or {}
  view.delta = view.delta or {}
  view.root_id = root_id
  view.scope_path = scope_path
  view.retired = false
  return view
end

function M.find_value(view, loc)
  local current = view
  while current do
    local rec = current.values[loc]
    if rec then
      return rec, current
    end
    current = current.parent
  end
  return nil
end

function M.cell(view, loc, trail)
  local rec = M.find_value(view, loc)
  if not rec then
    rec = { value = loc.value, version = loc.version or 0 }
    if trail then
      trail:set(view.values, loc, rec)
    else
      view.values[loc] = rec
    end
  end
  return rec
end

local function writable_cell(view, loc, trail)
  local rec = view.values[loc]
  if rec then
    return rec
  end

  local inherited = view.parent and M.find_value(view.parent, loc) or nil
  if inherited then
    rec = { value = inherited.value, version = inherited.version }
  else
    rec = { value = loc.value, version = loc.version or 0 }
  end
  if trail then
    trail:set(view.values, loc, rec)
  else
    view.values[loc] = rec
  end
  return rec
end

function M.read(view, loc, trail)
  return M.cell(view, loc, trail).value
end

function M.apply_patch_value(location, value, patch)
  return Algebra.apply(location, value, patch)
end

local function register_writer(view, location, writers)
  local bucket = writers and writers[location]
  if bucket then
    bucket[view.id] = view
  end
end

function M.stage(view, location, patch, trail, writers)
  local cell = writable_cell(view, location, trail)
  register_writer(view, location, writers)
  local summary = Algebra.stage(location, view.delta[location], patch, trail)
  local value = Algebra.apply(location, cell.value, patch)
  if trail then
    trail:set(view.delta, location, summary)
    trail:set(cell, 'value', value)
  else
    view.delta[location], cell.value = summary, value
  end
  return true
end

M.merge_parallel = Algebra.join
M.constraint_projection = Algebra.constraint

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
local function writer_candidates(state, loc)
  local writers = state.writers_by_location
  if not writers then
    return state.segments, false
  end
  local bucket = writers[loc]
  if not bucket then
    bucket = {}
    for view_id, view in pairs(state.segments) do
      if view.delta[loc] then
        bucket[view_id] = view
      end
    end
    writers[loc] = bucket
  end
  return bucket, true
end

function M.project(state, task, loc, orientation, trail)
  local own = state.segments[task.segment_id]
  local value = M.read(own, loc, trail)
  local used = {}
  local combined = nil

  local candidates, indexed = writer_candidates(state, loc)
  local view_ids = sorted_ids(candidates)
  for i = 1, #view_ids do
    local view_id = view_ids[i]
    local view = indexed and candidates[view_id] or state.segments[view_id]
    if view_id ~= task.segment_id and not view.retired then
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
  local own = state.segments[task.segment_id]
  local value = M.read(own, loc, trail)
  local steps = {}

  local candidates, indexed = writer_candidates(state, loc)
  local view_ids = sorted_ids(candidates)
  for i = 1, #view_ids do
    local view_id = view_ids[i]
    local view = indexed and candidates[view_id] or state.segments[view_id]
    if view_id ~= task.segment_id and not view.retired then
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

function M.join_segments(parent, children, mode, trail, writers)
  local writes = {}

  for i = 1, #children do
    local child = children[i]
    for loc, rec in pairs(child.values) do
      if child.delta[loc] then
        -- A writable child cell already contains its own patch.  Observe the
        -- common parent world here; the merged child patch is staged exactly
        -- once below.  Copying rec.value would apply non-idempotent patches
        -- twice when the parent had not previously materialised the location.
        M.cell(parent, loc, trail)
      elseif not M.find_value(parent, loc) then
        local observed = { value = rec.value, version = rec.version }
        if trail then
          trail:set(parent.values, loc, observed)
        else
          parent.values[loc] = observed
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
    M.stage(parent, loc, patch, trail, writers)
  end
  for i = 1, #children do
    if trail then
      trail:set(children[i], 'retired', true)
    else
      children[i].retired = true
    end
  end
  return true
end

function M.collect_candidate(root_views)
  local observations, writes
  for i = 1, #root_views do
    local view = root_views[i]
    for loc, rec in pairs(view.values) do
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

function M.validate_segment(view)
  for loc, rec in pairs((view and view.values) or {}) do
    if (loc.version or 0) ~= rec.version then
      return false, 'stale-location'
    end
  end
  return true
end

function M.commit_segment(view)
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

M.result_pack = IR.result_pack
M.predicate_holds = IR.predicate_holds
M.evaluate_claim = IR.evaluate_claim

return M

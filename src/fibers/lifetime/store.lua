-- Runtime-local transactional store for continuing Lifetimes.
--
-- Every custody boundary is a Lifetime node. The store is instantiated by a
-- Runtime and owns the sole transactional topology for that Runtime.

local Op = require('fibers.op')
local Effect = require('fibers.effect')
local Values = require('fibers.internal.values')
local StateMachine = require('fibers.resource.machine')

local Store = {}
Store.__index = Store

local function node_of(value)
  if type(value) ~= 'table' then return nil end
  return value._fibers_lifetime and value or value._lifetime
end

local boundary_of = node_of

local function view_of(node)
  return node and (node.value or node) or nil
end
local Phase = { live = 'live', closing = 'closing', closure_failed = 'closure_failed' }
local Ready, Wait = StateMachine.Ready, StateMachine.Wait

local function is_close_token(x)
  return type(x) == 'table' and x._fibers_close_token == true
end

local function copy_list(xs)
  local out = {}
  for i = 1, #(xs or {}) do out[i] = xs[i] end
  return out
end

local function copy_set(xs)
  local out = {}
  for k, v in pairs(xs or {}) do if v then out[k] = true end end
  return out
end

local function copy_record(r, public)
  if not r then return nil end
  local out = { _fibers_value = true }
  for field, value in pairs(r) do out[field] = value end
  local node = r.node or r.lifetime
  out.node, out.item, out.lifetime = node, view_of(node), node
  out.children = copy_list(r.children)
  if public then
    out.close_token = nil
    out.parent = view_of(r.parent)
    for i = 1, #out.children do out.children[i] = view_of(out.children[i]) end
  end
  return out
end

-- Small persistent maps are used because the proof evaluator may branch and
-- roll back the forest transactionally.
local TOMBSTONE = {}
local PMap = {}
PMap.__index = function(self, key)
  local value = rawget(self, '_delta')[key]
  if value ~= nil then
    if value == TOMBSTONE then return nil end
    return value
  end
  local parent = rawget(self, '_parent')
  return parent and parent[key] or nil
end
PMap.__newindex = function(self, key, value)
  rawget(self, '_delta')[key] = value == nil and TOMBSTONE or value
end
local function pmap(parent)
  return setmetatable({ _parent = parent, _delta = {}, _depth = parent and ((rawget(parent, '_depth') or 0) + 1) or 0 }, PMap)
end
local function pmap_local(map, key)
  return rawget(map, '_delta')[key] ~= nil
end
local function pmap_flatten(map)
  local flat, seen = pmap(nil), {}
  local delta, node = rawget(flat, '_delta'), map
  while node do
    for key, value in pairs(rawget(node, '_delta') or {}) do
      if not seen[key] then
        seen[key] = true
        if value ~= TOMBSTONE then delta[key] = value end
      end
    end
    node = rawget(node, '_parent')
  end
  return flat
end
local function pmap_child(parent)
  if parent and (rawget(parent, '_depth') or 0) > 24 then return pmap(pmap_flatten(parent)) end
  return pmap(parent)
end

local function boundary_value(bs)
  local out = {
    sealed = bs and bs.sealed == true or false,
    version = bs and bs.version or 0,
    count = bs and bs.count or 0,
    next_admission = bs and bs.next_admission or 0,
    order = copy_list(bs and bs.order),
    closure_phase = bs and bs.closure_phase or 'dormant',
  }
  if bs then
    out.closure_reason, out.closure_error = bs.closure_reason, bs.closure_error
  end
  return out
end

local function clone_state(s)
  return {
    boundaries = pmap_child(s and s.boundaries),
    records = pmap_child(s and s.records),
    record_count = s and s.record_count or 0,
    dirty_boundaries = copy_set(s and s.dirty_boundaries),
    dirty_items = copy_set(s and s.dirty_items),
    removed_records = s and s.removed_records or false,
  }
end

local function boundary_state(s, boundary)
  return s.boundaries[boundary] or boundary_value()
end

local function ensure_boundary(s, boundary)
  if not pmap_local(s.boundaries, boundary) then
    s.boundaries[boundary] = boundary_value(s.boundaries[boundary])
  end
  s.dirty_boundaries[boundary] = true
  return s.boundaries[boundary]
end

local function compact_order(s, boundary, bs)
  local out, seen = {}, {}
  for i = 1, #(bs.order or {}) do
    local item = bs.order[i]
    local rec = s.records[item]
    if rec and rec.custodian == boundary and not seen[item] then
      seen[item] = true
      out[#out + 1] = item
    end
  end
  bs.order = out
end

local function remove_record(s, boundary, item)
  local old = s.records[item]
  if not old or old.custodian ~= boundary then return end
  local bs = ensure_boundary(s, boundary)
  s.records[item] = nil
  s.removed_records = true
  s.record_count = math.max((s.record_count or 1) - 1, 0)
  bs.count = math.max((bs.count or 1) - 1, 0)
  compact_order(s, boundary, bs)
  s.dirty_items[item] = true
end

local function put_record(s, boundary, item, rec)
  local old = s.records[item]
  if old and old.custodian ~= boundary then
    remove_record(s, old.custodian, item)
    old = nil
  end
  local bs = ensure_boundary(s, boundary)
  local nr = copy_record(rec, false)
  nr.node, nr.lifetime = item, item
  nr.custodian = boundary
  s.records[item] = nr
  if not old then
    s.record_count = (s.record_count or 0) + 1
    bs.count = (bs.count or 0) + 1
    bs.order[#bs.order + 1] = item
  end
  s.dirty_items[item] = true
end

local function each_record(s, boundary, fn)
  local bs = boundary_state(s, boundary)
  for i = 1, #(bs.order or {}) do
    local item = bs.order[i]
    local rec = s.records[item]
    if rec and rec.custodian == boundary then fn(item, rec) end
  end
end

local function bump(bs) bs.version = (bs.version or 0) + 1 end

local function select_transition(name, ready, step, order)
  return StateMachine.isolated_select_when(name, ready, function(state, payload)
    if not ready(state, payload) then return Wait end
    return step(state, payload)
  end, order or 50)
end

local function walk_subtree(s, boundary, root, visit, seen)
  seen = seen or {}
  local rec = s.records[root]
  if not rec or rec.custodian ~= boundary or seen[root] then return end
  seen[root] = true
  visit(root, rec)
  for i = 1, #(rec.children or {}) do
    walk_subtree(s, boundary, rec.children[i], visit, seen)
  end
end

local function collect_subtree(s, boundary, root)
  local out = {}
  walk_subtree(s, boundary, root, function(item, rec) out[item] = rec end)
  return out
end

local function subtree_list(s, boundary, root, public)
  local out = {}
  walk_subtree(s, boundary, root, function(_, rec) out[#out + 1] = copy_record(rec, public) end)
  return out
end

local function node_label(node)
  return tostring((type(node) == 'table' and (node.name or node._fibers_id)) or node)
end

local function boundary_descendants(s, boundary)
  local roots = {}
  each_record(s, boundary, function(item, rec)
    if rec.parent == nil then roots[#roots + 1] = item end
  end)
  table.sort(roots, function(a, b) return node_label(a) < node_label(b) end)

  local out, prefix = {}, node_label(boundary)
  local function visit(item, rec, path)
    local bs = boundary_state(s, item)
    out[#out + 1] = {
      _fibers_value = true, node = item, item = view_of(item),
      id = item._fibers_id, name = item.name, path = path,
      role = rec.role, custody_phase = rec.phase,
      closure_phase = bs.closure_phase, closure_reason = bs.closure_reason,
      closure_error = bs.closure_error or rec.closure_error,
      child_count = #(rec.children or {}), host_hold = rec.role == 'host_hold',
    }
    for i = 1, #(rec.children or {}) do
      local child = rec.children[i]
      local child_rec = s.records[child]
      if child_rec and child_rec.custodian == boundary then
        visit(child, child_rec, path .. ' -> ' .. node_label(child))
      end
    end
  end
  for i = 1, #roots do
    local root, rec = roots[i], s.records[roots[i]]
    visit(root, rec, prefix .. ' -> ' .. node_label(root))
  end
  return out
end

-- A Lifetime boundary cannot be discharged while it still contains custody
-- records. This is the store-level form of complete containment: local
-- closure success is insufficient while descendants or host-backed records
-- remain accountable beneath the node.
local function containment_blockers(s, token)
  local blockers = {}
  for i = 1, #(token.records or {}) do
    local node = token.records[i].node or token.records[i].lifetime
    local bs = boundary_state(s, node)
    if (bs.count or 0) > 0 then
      local descendants = boundary_descendants(s, node)
      local host_holds = 0
      for j = 1, #descendants do
        if descendants[j].host_hold then host_holds = host_holds + 1 end
      end
      blockers[#blockers + 1] = {
        _fibers_value = true,
        node = node,
        item = view_of(node),
        id = node._fibers_id,
        name = node.name,
        count = bs.count,
        phase = bs.closure_phase,
        reason = bs.closure_reason,
        error = bs.closure_error,
        host_hold_count = host_holds,
        descendants = descendants,
      }
    end
  end
  return blockers
end

local function sorted_items(s, boundary, roots_only)
  local rows = {}
  each_record(s, boundary, function(item, rec)
    if not roots_only or rec.parent == nil then rows[#rows + 1] = { item = item, admission_order = rec.admission_order or 0 } end
  end)
  table.sort(rows, function(a, b)
    if roots_only and a.admission_order ~= b.admission_order then return a.admission_order > b.admission_order end
    return tostring(a.item._fibers_id or a.item.name or a.item) < tostring(b.item._fibers_id or b.item.name or b.item)
  end)
  local out = {}
  for i = 1, #rows do out[i] = rows[i].item end
  return out
end

local function rights_allow(rights, right)
  if right == nil or rights == nil or rights == '*' then return true end
  if type(rights) == 'string' then return rights == right or rights == '*' end
  if type(rights) ~= 'table' then return false end
  if rights[right] == true or rights['*'] == true then return true end
  for i = 1, #rights do if rights[i] == right or rights[i] == '*' then return true end end
  return false
end

local function valid_close_token(s, token)
  if not is_close_token(token) then return nil end
  local boundary = token.boundary
  if boundary == nil then return nil end
  local root = s.records[token.root]
  if not root or root.custodian ~= boundary or root.close_token ~= token then return nil end
  local subtree = collect_subtree(s, boundary, token.root)
  for _, rec in pairs(subtree) do
    if rec.close_token ~= token or (rec.phase ~= Phase.closing and rec.phase ~= Phase.closure_failed) then return nil end
  end
  return subtree
end

local closure_rank = {
  dormant = 0,
  open = 1,
  close_requested = 2,
  closing = 3,
  closure_failed = 4,
  closed = 5,
}

local function advance_closure(ns, node, phase, reason, err)
  local bs = ensure_boundary(ns, node)
  local current = bs.closure_phase or 'dormant'
  if (closure_rank[phase] or -1) >= (closure_rank[current] or -1) then
    bs.closure_phase = phase
    if reason ~= nil then bs.closure_reason = reason end
    if err ~= nil or phase ~= 'closure_failed' then bs.closure_error = err end
    bump(bs)
  end
  return bs
end

local function node_state(s, node)
  local rec, bs = s.records[node], s.boundaries[node]
  return {
    lifetime = node,
    custodian = rec and rec.custodian or nil,
    parent = rec and rec.parent or nil,
    children = rec and copy_list(rec.children) or {},
    custody_phase = rec and rec.phase or nil,
    closure_phase = (bs and bs.closure_phase) or node._terminal_phase or 'dormant',
    closure_reason = (bs and bs.closure_reason) or node._terminal_reason,
    closure_error = bs and bs.closure_error or nil,
    sealed = bs and bs.sealed == true or false,
    version = bs and bs.version or 0,
    closure_progress = rec and {
      state = rec.close_state,
      request_state = rec.close_request_state,
      force_state = rec.close_force_state,
      error = rec.closure_error,
    } or nil,
  }
end

local function new_close_token(store, boundary, root, records, purpose)
  store._next_close_token = store._next_close_token + 1
  return {
    _fibers_close_token = true, _fibers_value = true,
    id = 'close-token-' .. tostring(store._next_close_token),
    boundary = boundary, root = root, records = records, purpose = purpose,
    reason = type(purpose) == 'table' and purpose.reason or nil,
    started = false, running = false, complete = false,
  }
end

local function union_set(left, right)
  local out = copy_set(left)
  for value in pairs(right or {}) do out[value] = true end
  return out
end

local function merge_map(left, right)
  local out = {}
  for key, value in pairs(left or {}) do out[key] = value end
  for key, value in pairs(right or {}) do out[key] = value end
  return out
end

local function finalise_state(s)
  local changed_items = s.dirty_items or {}
  local changed_boundaries = s.dirty_boundaries or {}
  local retired_reasons = {}
  local removed_boundary = false

  for boundary in pairs(changed_boundaries) do
    local bs = boundary_state(s, boundary)
    if (bs.count or 0) == 0 and bs.closure_phase == 'closed' and s.boundaries[boundary] ~= nil then
      retired_reasons[boundary] = bs.closure_reason
      s.boundaries[boundary] = nil
      removed_boundary = true
    end
  end
  if removed_boundary then s.boundaries = pmap_flatten(s.boundaries) end
  if (s.record_count or 0) == 0 then
    s.records = pmap(nil)
  elseif s.removed_records then
    s.records = pmap_flatten(s.records)
  end
  s.removed_records = false
  s.dirty_boundaries, s.dirty_items = {}, {}
  return changed_items, retired_reasons
end

local StoreCommitKind
StoreCommitKind = Effect.kind({
  name = 'lifetime-store-commit',
  key = function(payload) return payload.store end,
  merge = function(left, right)
    return {
      store = left.store,
      after = right.after,
      changed_items = union_set(left.changed_items, right.changed_items),
      retired_reasons = merge_map(left.retired_reasons, right.retired_reasons),
    }
  end,
  prepare = function(_runtime, payload)
    local owner_runtime = payload.store.runtime
    local present, absent, retired_boundaries = {}, {}, {}
    for node in pairs(payload.changed_items or {}) do
      if payload.after.records[node] ~= nil then
        present[#present + 1] = node
      else
        absent[#absent + 1] = {
          node = node,
          reason = payload.retired_reasons[node],
        }
      end
    end
    for boundary, reason in pairs(payload.retired_reasons or {}) do
      if payload.after.boundaries[boundary] == nil then
        retired_boundaries[#retired_boundaries + 1] = { node = boundary, reason = reason }
      end
    end

    return {
      discharge = function()
        for i = 1, #present do
          local node = present[i]
          if node._bind_runtime_committed then node:_bind_runtime_committed(owner_runtime) end
        end
        for i = 1, #retired_boundaries do
          local entry = retired_boundaries[i]
          if entry.node._on_retired then entry.node:_on_retired(entry.reason) end
        end
        for i = 1, #present do
          local node = present[i]
          if node._on_admitted then node:_on_admitted() end
        end
        for i = 1, #absent do
          local entry = absent[i]
          if entry.node._admitted and entry.node._on_retired then entry.node:_on_retired(entry.reason) end
        end
        return true
      end,
    }
  end,
})

local function committed_write(store, after, ...)
  local changed_items, retired_reasons = finalise_state(after)
  local effect = Effect.of(StoreCommitKind, {
    store = store,
    after = after,
    changed_items = changed_items,
    retired_reasons = retired_reasons,
  })
  return Ready.write(after, effect, Values.pack(...))
end

local function op_transition(store, transition, payload)
  return store.store:transition_op(transition, payload or {})
end

local function committed_transition_op(store, transition, payload)
  return op_transition(store, transition, payload):and_then(Op.guard(function(effect, result, ...)
    if not Effect.is_effect(effect) or effect.kind ~= StoreCommitKind then
      return Op.always(effect, result, ...)
    end
    return Op.emit(effect):map(function() return Values.unpack(result) end)
  end))
end

local function query_value(s, p)
  local kind, rec = p.kind, p.item and s.records[p.item]
  if kind == 'node_state' then return node_state(s, p.node) end
  if kind == 'has_custody' then return rec ~= nil and rec.custodian == p.boundary end
  if kind == 'record' then
    return rec and rec.custodian == p.boundary and copy_record(rec, true) or nil
  end
  if kind == 'children' then
    return rec and rec.custodian == p.boundary and copy_list(rec.children) or nil
  end
  if kind == 'subtree' then
    return rec and rec.custodian == p.boundary and subtree_list(s, p.boundary, p.item, true) or nil
  end
  if kind == 'roots' then
    local nodes, out = sorted_items(s, p.boundary, true), {}
    for i = 1, #nodes do out[i] = view_of(nodes[i]) end
    return out
  end
  if kind == 'status' then
    local bs, custody, roots, closing, failed = boundary_state(s, p.boundary), 0, 0, 0, 0
    each_record(s, p.boundary, function(_, item)
      custody = custody + 1
      if item.parent == nil then roots = roots + 1 end
      if item.phase == Phase.closing then closing = closing + 1 end
      if item.phase == Phase.closure_failed or item.closure_failed then failed = failed + 1 end
    end)
    return { sealed = bs.sealed, open = not bs.sealed, custody_count = custody, root_count = roots,
      closing_count = closing, failed_count = failed, closure_failed_count = failed, version = bs.version }
  end
  if kind == 'active' then return rec ~= nil and rec.phase == Phase.live end
  if kind == 'authorise' then
    if not rec or rec.custodian ~= p.boundary then return false, nil end
    local phase = rec.phase
    local allowed = phase == Phase.live or (p.allow_closing and phase == Phase.closing)
    local rights = rec.rights or (type(rec.meta) == 'table' and rec.meta.rights or nil)
    return allowed and rights_allow(rights, p.right), phase
  end
  error('unknown lifetime query ' .. tostring(kind), 0)
end

local QUERY = StateMachine.isolated_query('lifetime.query', function(state, payload)
  return Ready.same(query_value(state, payload))
end, 10)

local function query_op(store, kind, payload)
  payload.kind = kind
  return op_transition(store, QUERY, payload)
end

local function phase_op(store, name, value, phase, reason, err, ready, result)
  local node = node_of(value)
  local t = select_transition('lifetime.' .. name, function(s)
    local bs = boundary_state(s, node)
    return ready and ready(bs) or bs.closure_phase ~= 'closed'
  end, function(s)
    local ns, before = clone_state(s), boundary_state(s, node).closure_phase or 'dormant'
    advance_closure(ns, node, phase, reason, err)
    return committed_write(store, ns, result and result(before) or true, reason)
  end)
  return committed_transition_op(store, t):or_else(Op.always(false, reason))
end

function Store.new(runtime)
  local initial_state = {
    boundaries = pmap(nil),
    records = pmap(nil),
    record_count = 0,
    dirty_boundaries = {},
    dirty_items = {},
    removed_records = false,
  }
  local forest = StateMachine.new(initial_state, 'lifetime-forest')
  forest._location.clone_value = nil
  local store = setmetatable({
    runtime = runtime,
    store = forest,
    _next_node = 0,
    _next_close_token = 0,
  }, Store)
  return store
end

function Store:attach_boundary(node, name)
  if type(node) ~= 'table' or node._fibers_lifetime ~= true then
    error('LifetimeStore expects a Lifetime node', 2)
  end
  if node.runtime and node.runtime ~= self.runtime then
    error('Lifetime already belongs to another Runtime', 2)
  end
  if node._fibers_id == nil then
    self._next_node = self._next_node + 1
    node._fibers_id = 'lifetime-' .. tostring(self._next_node)
  end
  node.name = name or node.name or node._fibers_id
  return node
end

function Store:activate_boundary(node)
  node = node_of(node)
  local state = self.store.value
  local bs = state.boundaries[node]
  if not bs then
    bs = boundary_value()
    bs.closure_phase = 'open'
    state.boundaries[node] = bs
  elseif bs.closure_phase == 'dormant' then
    bs.closure_phase = 'open'
  end
  return node
end


function Store:admit_op(view, root)
  root = node_of(root)
  if not root then error('LifetimeStore:admit_op expects a Lifetime', 2) end
  local boundary = boundary_of(view)
  local function current_records()
    -- The dormant graph remains mutable until admission commits. Re-read it
    -- for each transition attempt rather than freezing it as a side effect of
    -- constructing the admission Op.
    return root:record_map()
  end
  local t = select_transition('lifetime.admit', function(s)
    local bs = boundary_state(s, boundary)
    if bs.sealed or root._admitted then return false end
    if root.runtime and root.runtime ~= self.runtime then return false end
    for item in pairs(current_records()) do
      if item.runtime and item.runtime ~= self.runtime then return false end
      if item._admitted or s.records[item] ~= nil then return false end
    end
    return true
  end, function(s)
    local records = current_records()
    local ns = clone_state(s)
    local bs = ensure_boundary(ns, boundary)
    bs.next_admission = (bs.next_admission or 0) + 1
    local admission_order = bs.next_admission
    for item, rec in pairs(records) do
      local nr = copy_record(rec, false)
      nr.node, nr.lifetime = item, item
      if item == root then nr.admission_order = admission_order end
      put_record(ns, boundary, item, nr)
      local node_bs = ensure_boundary(ns, item)
      node_bs.closure_phase = 'open'
      node_bs.closure_reason = nil
      node_bs.closure_error = nil
    end
    bump(bs)
    return committed_write(self, ns, view_of(root))
  end, 40)
  return committed_transition_op(self, t)
end


function Store:move_op(view, item, target_view)
  item = node_of(item)
  local from_boundary, to_boundary = boundary_of(view), boundary_of(target_view)
  local t = select_transition('lifetime.move', function(s)
    local rec = s.records[item]
    if boundary_state(s, to_boundary).sealed or not rec or rec.custodian ~= from_boundary or rec.parent ~= nil then return false end
    local subtree = collect_subtree(s, from_boundary, item)
    for _, r in pairs(subtree) do if r.phase ~= Phase.live then return false end end
    return true
  end, function(s)
    if from_boundary == to_boundary then return committed_write(self, clone_state(s), view_of(item)) end
    local ns = clone_state(s)
    local from_bs, to_bs = ensure_boundary(ns, from_boundary), ensure_boundary(ns, to_boundary)
    local subtree = collect_subtree(ns, from_boundary, item)
    to_bs.next_admission = (to_bs.next_admission or 0) + 1
    local admission_order = to_bs.next_admission
    local copies = {}
    for child, rec in pairs(subtree) do copies[child] = copy_record(rec, false) end
    for child in pairs(subtree) do remove_record(ns, from_boundary, child) end
    for child, rec in pairs(copies) do
      if child == item then rec.admission_order = admission_order end
      put_record(ns, to_boundary, child, rec)
    end
    bump(from_bs); bump(to_bs)
    return committed_write(self, ns, view_of(item))
  end)
  return committed_transition_op(self, t)
end

function Store:_acquire_close_token_op(view, item, purpose)
  item = node_of(item)
  local boundary = boundary_of(view)
  local t = select_transition('lifetime.close.acquire', function(s)
    local root = s.records[item]
    if not root or root.custodian ~= boundary or root.parent ~= nil then return false end
    for _, rec in pairs(collect_subtree(s, boundary, item)) do if rec.phase ~= Phase.live then return false end end
    return true
  end, function(s)
    local ns = clone_state(s)
    local bs = ensure_boundary(ns, boundary)
    local records = subtree_list(ns, boundary, item, false)
    local token = new_close_token(self, boundary, item, records, purpose)
    for child, rec in pairs(collect_subtree(ns, boundary, item)) do
      local nr = copy_record(rec, false)
      nr.phase, nr.close_token, nr.close_token_id = Phase.closing, token, token.id
      nr.close_purpose, nr.close_reason = purpose, token.reason
      put_record(ns, boundary, child, nr)
    end
    bump(bs)
    return committed_write(self, ns, token)
  end)
  return committed_transition_op(self, t)
end

function Store:_resolve_close_token_op(token, kind, details)
  details = details or {}
  local boundary = token and token.boundary or nil
  local t = select_transition('lifetime.close.resolve', function(s) return valid_close_token(s, token) ~= nil end, function(s)
    local ns = clone_state(s)
    local bs = ensure_boundary(ns, boundary)
    local subtree = valid_close_token(ns, token)
    if kind == 'discharge' then
      local blockers = containment_blockers(s, token)
      if #blockers > 0 then
        return Ready.same(false, blockers)
      end
      for child in pairs(subtree) do
        local child_bs = ensure_boundary(ns, child)
        child_bs.closure_phase = 'closed'
        child_bs.closure_reason = token.reason
        child_bs.closure_error = nil
        bump(child_bs)
        remove_record(ns, boundary, child)
      end
    elseif kind == 'resume' then
      for child, rec in pairs(subtree) do
        local nr = copy_record(rec, false)
        nr.phase = Phase.closing
        nr.closure_failed, nr.closure_error, nr.closure_error_message = nil, nil, nil
        put_record(ns, boundary, child, nr)
        local child_bs = ensure_boundary(ns, child)
        if child_bs.closure_phase ~= 'closed' then child_bs.closure_phase = 'closing' end
        child_bs.closure_error = nil
      end
    elseif kind == 'fail' then
      local progress_by_item = {}
      for i = 1, #(details.progress or {}) do progress_by_item[details.progress[i].node or node_of(details.progress[i].item)] = details.progress[i] end
      local first_error = details.error or (details.failures and details.failures[1] and details.failures[1].error)
      for child, rec in pairs(subtree) do
        local nr, progress = copy_record(rec, false), progress_by_item[child]
        nr.phase = Phase.closure_failed
        nr.close_state = progress and progress.state or 'failed'
        nr.close_request_state = progress and progress.request_state or nil
        nr.close_force_state = progress and progress.force_state or nil
        nr.close_request_error = progress and progress.request_error or nil
        nr.close_force_error = progress and progress.force_error or nil
        local retained = (boundary_state(ns, child).count or 0) > 0
        nr.closure_failed = retained or not progress or progress.close_state ~= 'succeeded'
        nr.closure_error = progress and (progress.closure_error or progress.request_error or progress.force_error) or first_error
        if retained and nr.closure_error == nil then
          nr.closure_error = 'closure retained unresolved descendants'
        end
        nr.closure_error_message = nr.closure_error and tostring(nr.closure_error) or nil
        put_record(ns, boundary, child, nr)
        local child_bs = ensure_boundary(ns, child)
        if progress and progress.close_state == 'succeeded' and not retained then
          child_bs.closure_phase = 'closed'
          child_bs.closure_error = nil
        else
          child_bs.closure_phase = 'closure_failed'
          child_bs.closure_error = nr.closure_error or first_error
        end
        child_bs.closure_reason = token.reason
      end
    else
      error('unknown internal close-token resolution ' .. tostring(kind), 0)
    end
    bump(bs)
    if kind == 'discharge' then
      return committed_write(self, ns, true, view_of(token.root))
    end
    return committed_write(self, ns, view_of(token.root))
  end)
  return committed_transition_op(self, t)
end

function Store:request_close_op(value, reason)
  return phase_op(self, 'request_close', value, 'close_requested', reason, nil,
    function(bs) return bs.closure_phase ~= 'closed' and bs.closure_phase ~= 'closure_failed' end,
    function(before) return before ~= 'close_requested' and before ~= 'closing' end)
end

function Store:mark_closing_op(value, reason)
  return phase_op(self, 'mark_closing', value, 'closing', reason)
end

function Store:mark_closure_failed_op(value, err, reason)
  return phase_op(self, 'mark_closure_failed', value, 'closure_failed', reason, err)
end

function Store:mark_closed_op(value, reason)
  return phase_op(self, 'mark_closed', value, 'closed', reason, nil,
    function(bs) return bs.closure_phase ~= 'closed' and (bs.count or 0) == 0 end)
end

function Store:node_state_op(value) return query_op(self, 'node_state', { node = node_of(value) }) end

function Store:seal_op(view)
  local boundary = boundary_of(view)
  local t = select_transition('lifetime.seal', function(s) return not boundary_state(s, boundary).sealed end, function(s)
    local ns = clone_state(s); local bs = ensure_boundary(ns, boundary)
    bs.sealed = true; bump(bs)
    return committed_write(self, ns, true)
  end)
  return committed_transition_op(self, t)
end

function Store:changed_op(view, version)
  local boundary = boundary_of(view)
  local t = select_transition('lifetime.changed', function(s) return boundary_state(s, boundary).version ~= version end,
    function(s) return Ready.same(boundary_state(s, boundary).version) end)
  return op_transition(self, t)
end

function Store:has_custody_op(view, item) return query_op(self, 'has_custody', { boundary = boundary_of(view), item = node_of(item) }) end

function Store:record_op(view, item) return query_op(self, 'record', { boundary = boundary_of(view), item = node_of(item) }) end

function Store:children_op(view, item) return query_op(self, 'children', { boundary = boundary_of(view), item = node_of(item) }) end

function Store:subtree_op(view, item) return query_op(self, 'subtree', { boundary = boundary_of(view), item = node_of(item) }) end

function Store:roots_op(view) return query_op(self, 'roots', { boundary = boundary_of(view) }) end

function Store:status_op(view) return query_op(self, 'status', { boundary = boundary_of(view) }) end

function Store:active_op(item) return query_op(self, 'active', { item = node_of(item) }) end

function Store:custody_can_op(view, item, right, opts)
  return query_op(self, 'authorise', {
    boundary = boundary_of(view), item = node_of(item), right = right,
    allow_closing = opts and opts.allow_closing == true,
  })
end

function Store:current_state(value)
  local node = node_of(value)
  return node and node_state(self.store.value, node) or nil
end

function Store:current_custodian(value)
  local node = node_of(value)
  local rec = node and self.store.value.records[node] or nil
  return rec and rec.custodian or nil
end


function Store:current_records(view, roots_only)
  local state, boundary = self.store.value, boundary_of(view)
  local items = sorted_items(state, boundary, roots_only == true)
  local out = {}
  for i = 1, #items do
    local rec = state.records[items[i]]
    if rec and rec.custodian == boundary then
      out[#out + 1] = { item = view_of(items[i]), node = items[i], record = copy_record(rec, false) }
    end
  end
  return out
end

return Store

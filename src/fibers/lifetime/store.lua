-- Runtime-local transactional forest for continuing Lifetimes.
--
-- Each Lifetime node owns one authoritative kernel location containing exactly
-- two pieces of live topology: its custody record (the item side) and its
-- custody-boundary state (the owner side). There is no global forest value.
-- Multi-node changes are ordinary atomic Option compositions over only the
-- nodes they touch, so unrelated scopes no longer share a dependency location.

local Op = require('fibers.op')
local Effect = require('fibers.effect')
local Facility = require('fibers.resource.authoring')
local StateMachine = require('fibers.resource.machine')

local Store = {}
Store.__index = Store

local Ready, Wait = StateMachine.Ready, StateMachine.Wait
local Phase = { live = 'live', closing = 'closing', closure_failed = 'closure_failed' }
local RECORD_ABSENT = { _fibers_lifetime_record_absent = true }
local BOUNDARY_ABSENT = { _fibers_lifetime_boundary_absent = true }

local function node_of(value)
  if type(value) ~= 'table' then return nil end
  return value._fibers_lifetime and value or value._lifetime
end

local boundary_of = node_of

local function view_of(node)
  return node and (node._value or node) or nil
end

local function is_close_token(x)
  return type(x) == 'table' and x._fibers_close_token == true
end

local function copy_list(xs)
  local out = {}
  for i = 1, #(xs or {}) do out[i] = xs[i] end
  return out
end

local function copy_record(r)
  if not r or r == RECORD_ABSENT then return nil end
  local out = {}
  for field, value in pairs(r) do out[field] = value end
  out.children = copy_list(r.children)
  if r._members then out._members = copy_list(r._members) end
  return out
end

local function record_view(node, r)
  local out = copy_record(r)
  if not out then return nil end
  out._fibers_value, out.node, out.item = true, node, view_of(node)
  out.close_token, out._members, out.parent = nil, nil, view_of(r.parent)
  for i = 1, #out.children do out.children[i] = view_of(out.children[i]) end
  return out
end

local function new_boundary()
  return {
    sealed = false,
    count = 0,
    roots = {}, -- newest admission first, matching the former admission-order view
    closure_phase = 'dormant',
  }
end

local function copy_boundary(bs)
  if not bs or bs == BOUNDARY_ABSENT then return new_boundary() end
  return {
    sealed = bs.sealed == true,
    count = bs.count or 0,
    roots = copy_list(bs.roots),
    closure_phase = bs.closure_phase or 'dormant',
    closure_reason = bs.closure_reason,
    closure_error = bs.closure_error,
  }
end

local function boundary_state(bs)
  return (bs == nil or bs == BOUNDARY_ABSENT) and new_boundary() or bs
end

local STATUS_RESULT = Facility.result.project(function(state, leaf)
  local bs = boundary_state(state.boundary)
  return { sealed = bs.sealed == true, version = leaf.location.version or 0 }
end)

local function new_node_state()
  return { record = RECORD_ABSENT, boundary = BOUNDARY_ABSENT }
end

local function copy_node_state(state)
  return { record = state.record, boundary = state.boundary }
end

local function prepend_root(bs, root)
  local roots = bs.roots or {}
  local out = { root }
  for i = 1, #roots do
    if roots[i] ~= root then out[#out + 1] = roots[i] end
  end
  bs.roots = out
end

local function remove_root(bs, root)
  local roots, out, found = bs.roots or {}, {}, false
  for i = 1, #roots do
    if roots[i] == root then found = true else out[#out + 1] = roots[i] end
  end
  bs.roots = out
  return found
end

local function rights_allow(rights, right)
  if right == nil or rights == nil or rights == '*' then return true end
  if type(rights) == 'string' then return rights == right or rights == '*' end
  if type(rights) ~= 'table' then return false end
  if rights[right] == true or rights['*'] == true then return true end
  for i = 1, #rights do if rights[i] == right or rights[i] == '*' then return true end end
  return false
end

local closure_rank = {
  dormant = 0,
  open = 1,
  close_requested = 2,
  closing = 3,
  closure_failed = 4,
  closed = 5,
}

local function advance_closure(bs, phase, reason, err)
  local current = bs.closure_phase or 'dormant'
  if (closure_rank[phase] or -1) <= (closure_rank[current] or -1) then return false end
  bs.closure_phase = phase
  if reason ~= nil then bs.closure_reason = reason end
  if err ~= nil or phase ~= 'closure_failed' then bs.closure_error = err end
  return true
end

local function machine_op(store, node, transition, payload)
  store:attach_node(node)
  local location = node._lifetime_location
  local specs = rawget(location, '_lifetime_specs')
  if not specs then
    specs = setmetatable({}, { __mode = 'k' })
    rawset(location, '_lifetime_specs', specs)
  end
  local spec = specs[transition]
  if not spec then
    spec = StateMachine._compile(location, node, transition)
    specs[transition] = spec
  end
  return Facility.bind(spec, payload == nil and {} or payload)
end

-- Admission of an item is one-shot. Do not retain a compiled transition on
-- every live Lifetime for an operation which can never be performed again.
local function machine_once(store, node, transition, payload)
  store:attach_node(node)
  local spec = StateMachine._compile(node._lifetime_location, node, transition)
  return Facility.bind(spec, payload == nil and {} or payload)
end

local function roots_view(bs)
  bs = boundary_state(bs)
  local out = {}
  for i = 1, #(bs.roots or {}) do out[i] = view_of(bs.roots[i]) end
  return out
end

local function row1(rows, index)
  local row = rows[index]
  return row and row[1] or nil
end

-- Ordinary node fields are commit-local mirrors used by Task/Scope/domain
-- objects. The transactional topology itself lives solely in node locations.
local CommitKind
CommitKind = Effect.kind({
  name = 'lifetime-node-commit',
  key = function(payload) return payload.store end,
  merge = function(left, right)
    local changes = {}
    for node, change in pairs(left.changes or {}) do changes[node] = change end
    for node, change in pairs(right.changes or {}) do changes[node] = change end
    return { store = left.store, changes = changes }
  end,
  prepare = function(_runtime, payload)
    local owner_runtime = payload.store.runtime
    local changes = payload.changes or {}
    return {
      discharge = function()
        for node, change in pairs(changes) do
          if change.state == 'admitted' and node._bind_runtime_committed then
            node:_bind_runtime_committed(owner_runtime)
          end
        end
        for node, change in pairs(changes) do
          if change.state == 'admitted' then
            if node._on_admitted then node:_on_admitted() end
          elseif change.state == 'retired' then
            if node._on_retired then node:_on_retired(change.reason) end
          end
        end
        return true
      end,
    }
  end,
})

local function commit_effect(store, state, nodes, reason)
  local changes = {}
  for i = 1, #nodes do changes[nodes[i]] = { state = state, reason = reason } end
  return Effect.of(CommitKind, { store = store, changes = changes })
end

-- Queries ------------------------------------------------------------------

local NodeQuery = StateMachine.isolated_query('lifetime.node.query', function(state, p)
  local rec, bs = state.record, boundary_state(state.boundary)
  local kind = p.kind
  if kind == 'has_custody' then
    return Ready.same(rec ~= RECORD_ABSENT and rec.custodian == p.boundary)
  elseif kind == 'record' then
    return Ready.same(rec ~= RECORD_ABSENT and rec.custodian == p.boundary and record_view(p.item, rec) or nil)
  elseif kind == 'active' then
    return Ready.same(rec ~= RECORD_ABSENT and rec.phase == Phase.live)
  elseif kind == 'authorise' then
    if rec == RECORD_ABSENT or rec.custodian ~= p.boundary then return Ready.same(false, nil) end
    local phase = rec.phase
    local allowed = phase == Phase.live or (p.allow_closing and phase == Phase.closing)
    local rights = rec.rights or (type(rec.meta) == 'table' and rec.meta.rights or nil)
    return Ready.same(allowed and rights_allow(rights, p.right), phase)
  elseif kind == 'root' then
    if rec == RECORD_ABSENT or rec.custodian ~= p.boundary or rec.parent ~= nil then return Wait end
    return Ready.same(copy_record(rec))
  elseif kind == 'roots' then
    return Ready.same(roots_view(bs))
  elseif kind == 'live_member' then
    if rec == RECORD_ABSENT or rec.custodian ~= p.boundary or rec.phase ~= Phase.live then return Wait end
    return Ready.same(true)
  elseif kind == 'token_containment' then
    if rec == RECORD_ABSENT or rec.custodian ~= p.boundary or rec.close_token ~= p.token then return Wait end
    if rec.phase ~= Phase.closing and rec.phase ~= Phase.closure_failed then return Wait end
    return Ready.same(bs.count or 0, bs.closure_error)
  end
  error('unknown Lifetime node query ' .. tostring(kind), 0)
end, 10)

-- Node changes ---------------------------------------------------------------

local function new_close_token(store, boundary, root, members, purpose)
  store._next_close_token = store._next_close_token + 1
  return {
    _fibers_close_token = true, _fibers_value = true,
    id = 'close-token-' .. tostring(store._next_close_token),
    boundary = boundary, root = root, members = copy_list(members), records = {}, purpose = purpose,
    reason = type(purpose) == 'table' and purpose.reason or nil,
    started = false, running = false, complete = false,
  }
end

-- Admission has a lower serial order so an admission and a subsequent node
-- action can compose in the same transactional world without changing v1's
-- established order.
local AdmissionChange = StateMachine.isolated_select('lifetime.node.admission', function(state, p)
  if p.kind == 'prepare' then
    local bs = boundary_state(state.boundary)
    if bs.sealed or p.root._admitted then return Wait end
    local records, members, descendant_admitted = p.records()
    if descendant_admitted then return Wait end
    local next_bs = copy_boundary(bs)
    next_bs.count = (next_bs.count or 0) + #members
    prepend_root(next_bs, p.root)
    local next_state = copy_node_state(state); next_state.boundary = next_bs
    return Ready.write(next_state, records, members)
  elseif p.kind == 'item' then
    if state.record ~= RECORD_ABSENT or p.node._admitted then return Wait end
    local rec = copy_record(p.record)
    rec.custodian = p.boundary
    local bs = copy_boundary(state.boundary)
    bs.closure_phase, bs.closure_reason, bs.closure_error = 'open', nil, nil
    local next_state = copy_node_state(state); next_state.record, next_state.boundary = rec, bs
    return Ready.write(next_state, true)
  end
  error('unknown Lifetime admission change ' .. tostring(p.kind), 0)
end, 40)

local NodeChange = StateMachine.isolated_select('lifetime.node.change', function(state, p)
  local kind = p.kind
  if kind == 'move_root' then
    local rec = state.record
    if rec == RECORD_ABSENT or rec.custodian ~= p.from or rec.parent ~= nil or rec.phase ~= Phase.live then return Wait end
    local next_rec = copy_record(rec); next_rec.custodian = p.to
    local next_state = copy_node_state(state); next_state.record = next_rec
    return Ready.write(next_state, copy_list(rec._members or { p.item }))
  elseif kind == 'move_member' then
    local rec = state.record
    if rec == RECORD_ABSENT or rec.custodian ~= p.from or rec.phase ~= Phase.live then return Wait end
    local next_rec = copy_record(rec); next_rec.custodian = p.to
    local next_state = copy_node_state(state); next_state.record = next_rec
    return Ready.write(next_state, true)
  elseif kind == 'remove_root' then
    if state.boundary == BOUNDARY_ABSENT then return Wait end
    local bs = copy_boundary(state.boundary)
    if not remove_root(bs, p.root) then return Wait end
    bs.count = math.max((bs.count or p.count) - p.count, 0)
    local next_state = copy_node_state(state); next_state.boundary = bs
    return Ready.write(next_state, true)
  elseif kind == 'add_root' then
    local bs = boundary_state(state.boundary)
    if bs.sealed then return Wait end
    local next_bs = copy_boundary(bs)
    next_bs.count = (next_bs.count or 0) + p.count; prepend_root(next_bs, p.root)
    local next_state = copy_node_state(state); next_state.boundary = next_bs
    return Ready.write(next_state, true)
  elseif kind == 'acquire_root' then
    local rec = state.record
    if rec == RECORD_ABSENT or rec.custodian ~= p.boundary or rec.parent ~= nil or rec.phase ~= Phase.live then return Wait end
    local members = copy_list(rec._members or { p.item })
    local token = new_close_token(p.store, p.boundary, p.item, members, p.purpose)
    local before, next_rec = copy_record(rec), copy_record(rec)
    next_rec.phase, next_rec.close_token, next_rec.close_token_id = Phase.closing, token, token.id
    next_rec.close_purpose, next_rec.close_reason = p.purpose, token.reason
    local next_state = copy_node_state(state); next_state.record = next_rec
    return Ready.write(next_state, token, before)
  elseif kind == 'acquire_member' then
    local rec = state.record
    if rec == RECORD_ABSENT or rec.custodian ~= p.boundary or rec.phase ~= Phase.live then return Wait end
    local before, next_rec = copy_record(rec), copy_record(rec)
    next_rec.phase, next_rec.close_token, next_rec.close_token_id = Phase.closing, p.token, p.token.id
    next_rec.close_purpose, next_rec.close_reason = p.purpose, p.token.reason
    local next_state = copy_node_state(state); next_state.record = next_rec
    return Ready.write(next_state, before)
  elseif kind == 'touch_boundary' then
    local next_state = copy_node_state(state)
    if state.boundary ~= BOUNDARY_ABSENT then next_state.boundary = copy_boundary(state.boundary) end
    return Ready.write(next_state, true)
  elseif kind == 'discharge_member' then
    local rec, bs = state.record, boundary_state(state.boundary)
    if rec == RECORD_ABSENT or rec.custodian ~= p.boundary or rec.close_token ~= p.token then return Wait end
    if rec.phase ~= Phase.closing and rec.phase ~= Phase.closure_failed then return Wait end
    if (bs.count or 0) ~= 0 then return Wait end
    local next_state = copy_node_state(state); next_state.record, next_state.boundary = RECORD_ABSENT, BOUNDARY_ABSENT
    return Ready.write(next_state, true)
  elseif kind == 'resume_member' then
    local rec = state.record
    if rec == RECORD_ABSENT or rec.custodian ~= p.boundary or rec.close_token ~= p.token then return Wait end
    if rec.phase ~= Phase.closing and rec.phase ~= Phase.closure_failed then return Wait end
    local next_rec = copy_record(rec)
    next_rec.phase = Phase.closing
    next_rec.closure_failed, next_rec.closure_error, next_rec.closure_error_message = nil, nil, nil
    local bs = copy_boundary(state.boundary)
    if bs.closure_phase ~= 'closed' then bs.closure_phase = 'closing' end
    bs.closure_error = nil
    local next_state = copy_node_state(state); next_state.record, next_state.boundary = next_rec, bs
    return Ready.write(next_state, true)
  elseif kind == 'fail_member' then
    local rec, bs = state.record, boundary_state(state.boundary)
    if rec == RECORD_ABSENT or rec.custodian ~= p.boundary or rec.close_token ~= p.token then return Wait end
    if rec.phase ~= Phase.closing and rec.phase ~= Phase.closure_failed then return Wait end
    local progress, retained = p.progress, (bs.count or 0) > 0
    local next_rec = copy_record(rec)
    next_rec.phase = Phase.closure_failed
    next_rec.close_state = progress and progress.state or 'failed'
    next_rec.close_request_state = progress and progress.request_state or nil
    next_rec.close_force_state = progress and progress.force_state or nil
    next_rec.close_request_error = progress and progress.request_error or nil
    next_rec.close_force_error = progress and progress.force_error or nil
    next_rec.closure_failed = retained or not progress or progress.close_state ~= 'succeeded'
    next_rec.closure_error = progress and (progress.closure_error or progress.request_error or progress.force_error) or p.first_error
    if retained and next_rec.closure_error == nil then next_rec.closure_error = 'closure retained unresolved descendants' end
    next_rec.closure_error_message = next_rec.closure_error and tostring(next_rec.closure_error) or nil
    local next_boundary
    if progress and progress.close_state == 'succeeded' and not retained then
      next_boundary = BOUNDARY_ABSENT
    else
      next_boundary = copy_boundary(bs)
      next_boundary.closure_phase = 'closure_failed'
      next_boundary.closure_error = next_rec.closure_error or p.first_error
      next_boundary.closure_reason = p.token.reason
    end
    local next_state = copy_node_state(state); next_state.record, next_state.boundary = next_rec, next_boundary
    return Ready.write(next_state, true)
  elseif kind == 'seal' then
    local bs = boundary_state(state.boundary)
    if state.boundary == BOUNDARY_ABSENT or bs.sealed then return Wait end
    local next_bs = copy_boundary(bs); next_bs.sealed = true
    local next_state = copy_node_state(state); next_state.boundary = next_bs
    return Ready.write(next_state, true)
  elseif kind == 'phase' then
    local bs = boundary_state(state.boundary)
    if p.require_open and (state.boundary == BOUNDARY_ABSENT or bs.closure_phase == 'closed') then return Wait end
    if p.require_empty and (bs.count or 0) ~= 0 then return Wait end
    if p.ready and not p.ready(bs) then return Wait end
    local before, next_bs = bs.closure_phase or 'dormant', copy_boundary(bs)
    local changed = advance_closure(next_bs, p.phase, p.reason, p.err)
    local result = p.result and p.result(before) or true
    if p.phase == 'closed' and (next_bs.count or 0) == 0 then
      local next_state = copy_node_state(state); next_state.boundary = BOUNDARY_ABSENT
      return Ready.write(next_state, result, next_bs.closure_reason or p.reason, true)
    end
    if not changed then return Ready.same(result, bs.closure_reason or p.reason, false) end
    local next_state = copy_node_state(state); next_state.boundary = next_bs
    return Ready.write(next_state, result, next_bs.closure_reason or p.reason, false)
  end
  error('unknown Lifetime node change ' .. tostring(kind), 0)
end, 50)

-- Store --------------------------------------------------------------------

function Store.new(runtime)
  return setmetatable({ runtime = runtime, _next_node = 0, _next_close_token = 0 }, Store)
end

function Store:attach_node(node)
  if type(node) ~= 'table' or node._fibers_lifetime ~= true then error('LifetimeStore expects a Lifetime node', 2) end
  if node._runtime and node._runtime ~= self.runtime then error('Lifetime already belongs to another Runtime', 2) end
  if node._fibers_id == nil then
    self._next_node = self._next_node + 1
    node._fibers_id = 'lifetime-' .. tostring(self._next_node)
  end
  if not node._lifetime_location then
    node._lifetime_location = Facility.location(node, {
      algebra = 'machine', domain = 'plain', value = new_node_state(), key = 'lifetime-node',
    })
  end
  return node
end

function Store:activate_boundary(node)
  node = node_of(node); self:attach_node(node)
  local state = node._lifetime_location.value
  if state.boundary == BOUNDARY_ABSENT then
    local bs = new_boundary(); bs.closure_phase = 'open'
    state.boundary = bs
  elseif state.boundary.closure_phase == 'dormant' then
    state.boundary.closure_phase = 'open'
  end
  return node
end

function Store:admit_op(view, root)
  root = node_of(root)
  if not root then error('LifetimeStore:admit_op expects a Lifetime', 2) end
  local boundary = boundary_of(view)
  self:attach_node(boundary); self:attach_node(root)
  local function current_records() return root:_record_map() end
  return machine_op(self, boundary, AdmissionChange, { kind = 'prepare', root = root, records = current_records })
    :and_then(Op.guard(function(records, members)
      local operations = {}
      for i = 1, #members do
        local item = members[i]; self:attach_node(item)
        local rec = copy_record(records[item])
        if item == root then rec._members = copy_list(members) end
        operations[i] = machine_once(self, item, AdmissionChange, { kind = 'item', node = item, boundary = boundary, record = rec })
      end
      return Op.each(operations)
        :and_then(Op.emit(commit_effect(self, 'admitted', members)))
        :map(function() return view_of(root) end)
    end))
end

function Store:move_op(view, item, target_view)
  item = node_of(item)
  local from_boundary, to_boundary = boundary_of(view), boundary_of(target_view)
  self:attach_node(from_boundary); self:attach_node(to_boundary); self:attach_node(item)
  if from_boundary == to_boundary then
    return machine_op(self, item, NodeQuery, { kind = 'root', boundary = from_boundary })
      :and_then(Op.guard(function(root_rec)
        local members = copy_list(root_rec._members or { item })
        local operations = {}
        for i = 1, #members do operations[i] = machine_op(self, members[i], NodeQuery, { kind = 'live_member', boundary = from_boundary }) end
        return Op.each(operations):map(function() return view_of(item) end)
      end))
  end
  return machine_op(self, item, NodeChange, { kind = 'move_root', item = item, from = from_boundary, to = to_boundary })
    :and_then(Op.guard(function(members)
      local operations = {
        machine_op(self, from_boundary, NodeChange, { kind = 'remove_root', root = item, count = #members }),
        machine_op(self, to_boundary, NodeChange, { kind = 'add_root', root = item, count = #members }),
      }
      for i = 2, #members do
        operations[#operations + 1] = machine_op(self, members[i], NodeChange, { kind = 'move_member', from = from_boundary, to = to_boundary })
      end
      return Op.each(operations):map(function() return view_of(item) end)
    end))
end

function Store:_acquire_close_token_op(view, item, purpose)
  item = node_of(item)
  local boundary = boundary_of(view)
  return machine_op(self, item, NodeChange, { kind = 'acquire_root',
    store = self, item = item, boundary = boundary, purpose = purpose,
  }):and_then(Op.guard(function(token, root_before)
    local members = token.members
    local operations = { machine_op(self, boundary, NodeChange, { kind = 'touch_boundary' }) }
    for i = 2, #members do
      operations[#operations + 1] = machine_op(self, members[i], NodeChange, { kind = 'acquire_member',
        boundary = boundary, token = token, purpose = purpose,
      })
    end
    return Op.each(operations):map(function(rows)
      local records = {}
      local root_row = copy_record(root_before); root_row.node, root_row.item = item, view_of(item); records[1] = root_row
      for i = 2, #members do
        local rec = copy_record(row1(rows, i))
        rec.node, rec.item = members[i], view_of(members[i])
        records[i] = rec
      end
      token.records = records
      return token
    end)
  end))
end

local function containment_op(store, token)
  local operations = {}
  for i = 1, #(token.members or {}) do
    operations[i] = machine_op(store, token.members[i], NodeQuery, {
      kind = 'token_containment', boundary = token.boundary, token = token,
    })
  end
  return Op.each(operations):map(function(rows)
    local blockers = {}
    for i = 1, #(token.records or {}) do
      local count, err = rows[i][1], rows[i][2]
      if (count or 0) > 0 then
        local node = token.records[i].node
        blockers[#blockers + 1] = { node = node, item = view_of(node), count = count, error = err }
      end
    end
    return blockers
  end)
end

local function progress_map(details)
  local out = {}
  for i = 1, #(details.progress or {}) do
    local row = details.progress[i]; out[row.node or node_of(row.item)] = row
  end
  return out
end

function Store:_resolve_close_token_op(token, kind, details)
  details = details or {}
  if not is_close_token(token) or not token.boundary or not token.root then return Op.never() end
  local boundary, members = token.boundary, token.members or {}
  return containment_op(self, token):and_then(Op.guard(function(blockers)
    if kind == 'discharge' then
      if #blockers > 0 then return Op.always(false, blockers) end
      local operations = { machine_op(self, boundary, NodeChange, { kind = 'remove_root', root = token.root, count = #members }) }
      for i = 1, #members do
        operations[#operations + 1] = machine_op(self, members[i], NodeChange, { kind = 'discharge_member',
          boundary = boundary, token = token,
        })
      end
      return Op.each(operations)
        :and_then(Op.emit(commit_effect(self, 'retired', members, token.reason)))
        :map(function() return true, view_of(token.root) end)
    elseif kind == 'resume' then
      local operations = { machine_op(self, boundary, NodeChange, { kind = 'touch_boundary' }) }
      for i = 1, #members do
        operations[#operations + 1] = machine_op(self, members[i], NodeChange, { kind = 'resume_member', boundary = boundary, token = token })
      end
      return Op.each(operations):map(function() return view_of(token.root) end)
    elseif kind == 'fail' then
      local retained = {}; for i = 1, #blockers do retained[blockers[i].node] = true end
      local by_item = progress_map(details)
      local first_error = details.error or (details.failures and details.failures[1] and details.failures[1].error)
      local operations = { machine_op(self, boundary, NodeChange, { kind = 'touch_boundary' }) }
      for i = 1, #members do
        local node, progress = members[i], by_item[members[i]]
        operations[#operations + 1] = machine_op(self, node, NodeChange, { kind = 'fail_member',
          boundary = boundary, token = token, progress = progress, first_error = first_error,
          retained = retained[node] == true,
        })
      end
      return Op.each(operations):map(function() return view_of(token.root) end)
    end
    error('unknown internal close-token resolution ' .. tostring(kind), 0)
  end))
end

local function phase_op(store, value, phase, reason, err, ready, result, require_empty)
  local node = node_of(value)
  return machine_op(store, node, NodeChange, { kind = 'phase',
    phase = phase, reason = reason, err = err, ready = ready, result = result,
    require_empty = require_empty, require_open = phase ~= 'closed',
  }):and_then(Op.guard(function(first, recorded_reason, retired)
    if retired then
      return Op.emit(commit_effect(store, 'retired', { node }, recorded_reason))
        :map(function() return first, recorded_reason end)
    end
    return Op.always(first, recorded_reason)
  end)):or_else(Op.always(false, reason))
end

function Store:request_close_op(value, reason)
  return phase_op(self, value, 'close_requested', reason, nil,
    function(bs) return bs.closure_phase ~= 'closed' and bs.closure_phase ~= 'closure_failed' end,
    function(before) return before ~= 'close_requested' and before ~= 'closing' end)
end

function Store:mark_closing_op(value, reason)
  return phase_op(self, value, 'closing', reason)
end

function Store:mark_closure_failed_op(value, err, reason)
  return phase_op(self, value, 'closure_failed', reason, err)
end

function Store:mark_closed_op(value, reason)
  return phase_op(self, value, 'closed', reason, nil,
    function(bs) return bs.closure_phase ~= 'closed' end, nil, true)
end

function Store:seal_op(view)
  return machine_op(self, boundary_of(view), NodeChange, { kind = 'seal' })
end

function Store:changed_op(view, version)
  local node = boundary_of(view)
  self:attach_node(node)
  local location = node._lifetime_location
  local spec = rawget(location, '_lifetime_changed_spec')
  if not spec then
    spec = Facility.version_wait(location, node)
    rawset(location, '_lifetime_changed_spec', spec)
  end
  return Facility.bind(spec, version):map(function(_, current_version)
    return current_version
  end)
end

function Store:has_custody_op(view, item)
  local node = node_of(item)
  return machine_op(self, node, NodeQuery, { kind = 'has_custody', boundary = boundary_of(view), item = node })
end

function Store:record_op(view, item)
  local node = node_of(item)
  return machine_op(self, node, NodeQuery, { kind = 'record', boundary = boundary_of(view), item = node })
end

function Store:roots_op(view)
  return machine_op(self, boundary_of(view), NodeQuery, { kind = 'roots' })
end

function Store:status_op(view)
  local node = boundary_of(view)
  self:attach_node(node)
  local location = node._lifetime_location
  local op = rawget(location, '_lifetime_status_op')
  if not op then
    op = Facility.op(Facility.read(location, STATUS_RESULT, node))
    rawset(location, '_lifetime_status_op', op)
  end
  return op
end

function Store:active_op(item)
  local node = node_of(item)
  return machine_op(self, node, NodeQuery, { kind = 'active', item = node })
end

function Store:custody_can_op(view, item, right, opts)
  local node = node_of(item)
  return machine_op(self, node, NodeQuery, {
    kind = 'authorise', boundary = boundary_of(view), item = node, right = right,
    allow_closing = opts and opts.allow_closing == true,
  })
end

-- Direct internal observation is restricted to points where no transaction is
-- in flight (construction/outcome accounting and tests).
function Store:_node_parts(value)
  local node = node_of(value)
  if not node then return nil end
  self:attach_node(node)
  local state = node._lifetime_location.value
  local rec, boundary = state.record, state.boundary
  if rec == RECORD_ABSENT then rec = nil end
  if boundary == BOUNDARY_ABSENT then boundary = nil end
  return node, rec, boundary
end

function Store:_custodian(value)
  local _, rec = self:_node_parts(value)
  return rec and rec.custodian or nil
end

function Store:_closure_phase(value)
  local node, _, boundary = self:_node_parts(value)
  return boundary and boundary.closure_phase or node and node._terminal_phase or 'dormant'
end

function Store:_roots(view)
  local boundary = boundary_of(view)
  local _, _, bs = self:_node_parts(boundary)
  bs = boundary_state(bs)
  return copy_list(bs.roots)
end

return Store

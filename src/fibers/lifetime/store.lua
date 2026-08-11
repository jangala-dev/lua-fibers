-- Runtime-local transactional custody tree for continuing Lifetimes.
--
-- Each Lifetime owns one authoritative kernel location.  The location contains
-- only mutable lifecycle/custody facts; immutable description (protocol, role,
-- rights and metadata) stays on the Lifetime object itself.

local Op = require('fibers.op')
local Effect = require('fibers.effect')
local Facility = require('fibers.resource.authoring')
local StateMachine = require('fibers.resource.machine')
local Grant = require('fibers.grant')

local Store = {}
Store.__index = Store

local Ready, Wait = StateMachine.Ready, StateMachine.Wait

local function node_of(value)
  if type(value) ~= 'table' then return nil end
  return value._fibers_lifetime and value or value._lifetime
end

local custodian_of = node_of

local function view_of(node)
  return node and (node._value or node) or nil
end

local function is_close_claim(x)
  return type(x) == 'table' and x._fibers_close_claim == true
end

local function copy_list(xs)
  local out = {}
  for i = 1, #(xs or {}) do out[i] = xs[i] end
  return out
end

local function copy_close_request(request)
  if type(request) ~= 'table' then return nil end
  return {
    reason = request.reason,
    interrupt = request.interrupt == true,
    interrupt_reason = request.interrupt_reason,
  }
end

local function new_node_state()
  return {
    phase = 'dormant',
    custodian = nil,
    children = {}, -- newest admission first
    sealed = false,
    close_request = nil,
    closure_fault = nil,
    close_claim = nil,
  }
end

local function copy_state(state)
  return {
    phase = state.phase or 'dormant',
    custodian = state.custodian,
    children = copy_list(state.children),
    sealed = state.sealed == true,
    close_request = copy_close_request(state.close_request),
    closure_fault = state.closure_fault,
    close_claim = state.close_claim,
  }
end

local function close_reason(state)
  local request = state and state.close_request
  return type(request) == 'table' and request.reason or nil
end

local function ensure_closing(state, reason)
  if state.phase == 'retired' or state.phase == 'dormant' then return false end
  local changed = state.phase ~= 'closing'
  state.phase = 'closing'
  if state.close_request == nil then
    state.close_request = { reason = reason, interrupt = false }
    changed = true
  end
  return changed
end

local function is_owned(state)
  return state.phase == 'live' or state.phase == 'closing'
end

local function custody_snapshot(node, state)
  if not is_owned(state) then return nil end
  return {
    _fibers_value = true,
    node = node,
    item = view_of(node),
    custodian = state.custodian,
    phase = state.phase,
    closure_fault = state.closure_fault,
  }
end

local function rights_allow(rights, right)
  if right == nil or rights == nil or rights == '*' then return true end
  if type(rights) == 'string' then return rights == right or rights == '*' end
  if type(rights) ~= 'table' then return false end
  if rights[right] == true or rights['*'] == true then return true end
  for i = 1, #rights do
    if rights[i] == right or rights[i] == '*' then return true end
  end
  return false
end

local function prepend_child(state, child)
  local children, out = state.children or {}, { child }
  for i = 1, #children do
    if children[i] ~= child then out[#out + 1] = children[i] end
  end
  state.children = out
end

local function remove_child(state, child)
  local children, out, found = state.children or {}, {}, false
  for i = 1, #children do
    if children[i] == child then found = true else out[#out + 1] = children[i] end
  end
  state.children = out
  return found
end

local function children_view(state)
  local out = {}
  for i = 1, #(state.children or {}) do out[i] = view_of(state.children[i]) end
  return out
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

local function machine_once(store, node, transition, payload)
  store:attach_node(node)
  local spec = StateMachine._compile(node._lifetime_location, node, transition)
  return Facility.bind(spec, payload == nil and {} or payload)
end

-- Commit-local mirrors used only to bind/activate/retire ordinary Lua views.
local CommitKind = Effect.kind({
  name = 'lifetime-admission',
  key = function(payload) return payload.store end,
  merge = function(left, right)
    local nodes = {}
    for node in pairs(left.nodes or {}) do nodes[node] = true end
    for node in pairs(right.nodes or {}) do nodes[node] = true end
    return { store = left.store, nodes = nodes }
  end,
  prepare = function(_runtime, payload)
    local runtime, nodes = payload.store.runtime, payload.nodes or {}
    return { discharge = function()
      for node in pairs(nodes) do node:_bind_runtime_committed(runtime) end
      for node in pairs(nodes) do node:_on_admitted() end
      for node in pairs(nodes) do node:_activate_committed(runtime) end
      return true
    end }
  end,
})

local function admission_effect(store, node)
  return Effect.of(CommitKind, { store = store, nodes = { [node] = true } })
end

-- Queries ------------------------------------------------------------------

local NodeQuery = StateMachine.isolated_query('lifetime.node.query', function(state, p)
  local kind = p.kind
  if kind == 'has_custody' then
    return Ready.same(is_owned(state) and state.custodian == p.custodian)
  elseif kind == 'active' then
    return Ready.same(state.phase == 'live')
  elseif kind == 'authorise' then
    if not is_owned(state) or state.custodian ~= p.custodian then return Ready.same(false, nil) end
    local allowed = state.phase == 'live' or (p.allow_closing and state.phase == 'closing')
    local rights = p.item._rights or (type(p.item._meta) == 'table' and p.item._meta.rights or nil)
    return Ready.same(allowed and rights_allow(rights, p.right), state.phase)
  elseif kind == 'owned_by' then
    if not is_owned(state) or state.custodian ~= p.custodian then return Wait end
    return Ready.same(custody_snapshot(p.item, state))
  elseif kind == 'children' then
    return Ready.same(children_view(state))
  elseif kind == 'sealed' then
    if not state.sealed then return Wait end
    return Ready.same(true)
  elseif kind == 'custodian' then
    return Ready.same(is_owned(state) and state.custodian or nil)
  elseif kind == 'close_requested' then
    if state.close_request == nil and state.phase ~= 'retired' then return Wait end
    return Ready.same(close_reason(state))
  elseif kind == 'cancel_requested' then
    local request = state.close_request
    if type(request) ~= 'table' or request.interrupt ~= true then return Wait end
    return Ready.same(true, request.interrupt_reason or request.reason)
  elseif kind == 'retired' then
    if state.phase ~= 'retired' then return Wait end
    return Ready.same(true, close_reason(state))
  elseif kind == 'close_claim' then
    return Ready.same(state.close_claim, state.closure_fault)
  elseif kind == 'claim_containment' then
    if not is_owned(state) or state.custodian ~= p.custodian or state.close_claim ~= p.authority then return Wait end
    local unresolved = 0
    local members = p.claim.member_set or {}
    for i = 1, #(state.children or {}) do
      if not members[state.children[i]] then unresolved = unresolved + 1 end
    end
    return Ready.same(unresolved, state.closure_fault)
  end
  error('unknown Lifetime node query ' .. tostring(kind), 0)
end, 10)

-- Node changes -------------------------------------------------------------

local AdmissionChange = StateMachine.isolated_select('lifetime.node.admission', function(state, p)
  if p.kind == 'prepare' then
    if state.sealed or state.phase ~= 'live' then return Wait end
    local next = copy_state(state)
    prepend_child(next, p.child)
    return Ready.write(next, true)
  elseif p.kind == 'item' then
    if state.phase ~= 'dormant' then return Wait end
    local next = copy_state(state)
    next.phase = 'live'
    next.custodian = p.custodian
    next.sealed = false
    next.close_request = nil
    next.closure_fault = nil
    next.close_claim = nil
    return Ready.write(next, true)
  end
  error('unknown Lifetime admission change ' .. tostring(p.kind), 0)
end, 40)

local NodeChange = StateMachine.isolated_select('lifetime.node.change', function(state, p)
  local kind = p.kind
  if kind == 'move_custody' then
    if state.phase ~= 'live' or state.custodian ~= p.from or state.close_claim ~= nil then return Wait end
    local next = copy_state(state)
    next.custodian = p.to
    return Ready.write(next, true)
  elseif kind == 'remove_child' then
    if p.for_move and state.phase ~= 'live' then return Wait end
    local next = copy_state(state)
    if not remove_child(next, p.child) then return Wait end
    return Ready.write(next, true)
  elseif kind == 'add_child' then
    if state.sealed or state.phase ~= 'live' then return Wait end
    local next = copy_state(state)
    prepend_child(next, p.child)
    return Ready.write(next, true)
  elseif kind == 'claim_descendants' then
    if state.phase == 'retired' then return Ready.same(p.already_retired) end
    if state.close_claim ~= nil then
      return Ready.same({ _fibers_value = true, _fibers_close_delegated = true, authority = state.close_claim })
    end
    if state.phase ~= 'live' and state.phase ~= 'closing' then return Wait end
    local next = copy_state(state)
    next.close_claim = p.authority
    next.sealed = true
    ensure_closing(next, p.reason)
    return Ready.write(next, true)
  elseif kind == 'release_descendants_claim' then
    if state.close_claim ~= p.authority then return Wait end
    local next = copy_state(state)
    for i = 1, #(p.children or {}) do
      if not remove_child(next, p.children[i]) then return Wait end
    end
    next.close_claim = nil
    next.closure_fault = nil
    return Ready.write(next, true)
  elseif kind == 'restart_claim' then
    if state.close_claim ~= p.authority or state.closure_fault ~= p.failure then return Wait end
    local next = copy_state(state)
    next.closure_fault = nil
    return Ready.write(next, true)
  elseif kind == 'fail_claim' then
    if state.close_claim ~= p.authority then return Wait end
    local next = copy_state(state)
    next.closure_fault = p.failure
    return Ready.write(next, true)
  elseif kind == 'claim_subject' then
    if state.phase == 'retired' then return Ready.same(p.already_retired) end
    if state.close_claim ~= nil and p.delegate_existing then
      return Ready.same({ _fibers_value = true, _fibers_close_delegated = true, authority = state.close_claim })
    end
    if (state.phase ~= 'live' and state.phase ~= 'closing')
      or state.custodian ~= p.custodian or state.close_claim ~= nil then
      return Wait
    end
    local before, next = custody_snapshot(p.item, state), copy_state(state)
    next.close_claim = p.authority
    ensure_closing(next, p.reason)
    return Ready.write(next, before)
  elseif kind == 'acquire_member' then
    if (state.phase ~= 'live' and state.phase ~= 'closing')
      or state.custodian ~= p.custodian or state.close_claim ~= nil then
      return Wait
    end
    local before, next = custody_snapshot(p.item, state), copy_state(state)
    next.close_claim = p.authority
    ensure_closing(next, p.reason)
    return Ready.write(next, before)
  elseif kind == 'discharge_member' then
    if not is_owned(state) or state.custodian ~= p.custodian or state.close_claim ~= p.authority then return Wait end
    local next = copy_state(state)
    for i = 1, #(p.children or {}) do
      if not remove_child(next, p.children[i]) then return Wait end
    end
    if #(next.children or {}) ~= 0 then return Wait end
    next.phase = 'retired'
    next.custodian = nil
    next.sealed = true
    next.children = {}
    next.closure_fault = nil
    next.close_claim = nil
    if next.close_request == nil then next.close_request = { reason = p.reason, interrupt = false } end
    return Ready.write(next, true)
  elseif kind == 'restart_member' then
    if not is_owned(state) or state.custodian ~= p.custodian or state.close_claim ~= p.authority then return Wait end
    local next = copy_state(state)
    next.closure_fault = nil
    return Ready.write(next, true)
  elseif kind == 'fail_member' then
    if not is_owned(state) or state.custodian ~= p.custodian or state.close_claim ~= p.authority then return Wait end
    local progress, retained = p.progress, #(state.children or {}) > 0
    local fault = progress and (progress.closure_error or progress.request_error or progress.force_error) or p.first_error
    if retained and fault == nil then fault = 'closure retained unresolved descendants' end
    local next = copy_state(state)
    next.phase = 'closing'
    if next.close_request == nil then next.close_request = { reason = p.reason, interrupt = false } end
    next.closure_fault = fault or p.first_error
    return Ready.write(next, true)
  elseif kind == 'request_cancel' then
    if state.phase == 'retired' or state.phase == 'dormant' then return Wait end
    local next = copy_state(state)
    ensure_closing(next, p.reason)
    local request = next.close_request or { reason = p.reason, interrupt = false }
    local recorded_reason = request.interrupt_reason or request.reason or p.reason
    if request.interrupt then return Ready.same(false, recorded_reason) end
    request.interrupt = true
    request.interrupt_reason = p.reason
    next.close_request = request
    return Ready.write(next, true, p.reason)
  elseif kind == 'seal' then
    if state.phase == 'dormant' or state.phase == 'retired' or state.sealed then return Wait end
    local next = copy_state(state)
    next.sealed = true
    return Ready.write(next, true)
  elseif kind == 'request_close' then
    if state.phase == 'dormant' or state.phase == 'retired' then return Wait end
    local before, next = state.phase, copy_state(state)
    local changed = ensure_closing(next, p.reason)
    local first = before == 'live'
    if not changed then return Ready.same(first, close_reason(state) or p.reason) end
    return Ready.write(next, first, close_reason(next) or p.reason)
  elseif kind == 'record_fault' then
    if state.phase == 'dormant' or state.phase == 'retired' then return Wait end
    local next = copy_state(state)
    ensure_closing(next, p.reason)
    local changed = next.closure_fault ~= p.err
    next.closure_fault = p.err
    if not changed then return Ready.same(true, close_reason(next) or p.reason) end
    return Ready.write(next, true, close_reason(next) or p.reason)
  end
  error('unknown Lifetime node change ' .. tostring(kind), 0)
end, 50)

-- Store --------------------------------------------------------------------

function Store.new(runtime)
  return setmetatable({ runtime = runtime }, Store)
end

function Store:attach_node(node)
  if type(node) ~= 'table' or node._fibers_lifetime ~= true then
    error('LifetimeStore expects a Lifetime node', 2)
  end
  if node._runtime and node._runtime ~= self.runtime then
    error('Lifetime already belongs to another Runtime', 2)
  end
  if not node._lifetime_location then
    node._lifetime_location = Facility.location(node, {
      algebra = 'machine', domain = 'plain', value = new_node_state(), key = 'lifetime-node',
    })
  end
  return node
end

function Store:_bootstrap_root(node)
  node = node_of(node)
  self:attach_node(node)
  local state = node._lifetime_location.value
  if state.phase == 'dormant' then state.phase = 'live' end
  return node
end

-- Runtime bootstrap only: attach a top-level Scope beneath the distinguished
-- Runtime root before user execution begins. Ordinary application admission is
-- always transactional through admit_op.
function Store:_bootstrap_admit(parent, child)
  parent, child = node_of(parent), node_of(child)
  self:attach_node(parent)
  self:attach_node(child)
  local parent_state, child_state = parent._lifetime_location.value, child._lifetime_location.value
  if parent_state.phase ~= 'live' or parent_state.sealed then
    error('Runtime root cannot admit a bootstrap Lifetime', 2)
  end
  if child_state.phase ~= 'dormant' then
    if child_state.custodian == parent then return child end
    error('bootstrap Lifetime is not dormant', 2)
  end
  prepend_child(parent_state, child)
  child_state.phase = 'live'
  child_state.custodian = parent
  child:_bind_runtime_committed(self.runtime)
  if child._on_admitted then child:_on_admitted() end
  if child._activate_committed then child:_activate_committed(self.runtime) end
  return child
end

local function admit_one_op(store, custodian, node)
  store:attach_node(custodian)
  store:attach_node(node)
  return machine_op(store, custodian, AdmissionChange, { kind = 'prepare', child = node })
    :and_then(machine_once(store, node, AdmissionChange, { kind = 'item', node = node, custodian = custodian }))
    :and_then(Op.emit(admission_effect(store, node)))
    :map(function() return view_of(node) end)
end

local function admit_tree_op(store, custodian, node)
  local children = node:_construction_children_snapshot()
  local op = admit_one_op(store, custodian, node)
  for i = #children, 1, -1 do
    op = op:and_then(admit_tree_op(store, node, children[i]))
  end
  return op:map(function() return view_of(node) end)
end

function Store:admit_op(view, subject)
  subject = node_of(subject)
  if not subject then error('LifetimeStore:admit_op expects a Lifetime', 2) end
  local store, custodian = self, custodian_of(view)
  return Op.guard(function() return admit_tree_op(store, custodian, subject) end)
end

function Store:move_op(view, item, target_view)
  item = node_of(item)
  local from_custodian, to_custodian = custodian_of(view), custodian_of(target_view)
  self:attach_node(from_custodian)
  self:attach_node(to_custodian)
  self:attach_node(item)
  if from_custodian == to_custodian then
    return machine_op(self, item, NodeQuery, { kind = 'owned_by', custodian = from_custodian, item = item })
      :map(function() return view_of(item) end)
  end
  return machine_op(self, item, NodeChange, { kind = 'move_custody', item = item, from = from_custodian, to = to_custodian })
    :and_then(Op.each({
      machine_op(self, from_custodian, NodeChange, { kind = 'remove_child', child = item, for_move = true }),
      machine_op(self, to_custodian, NodeChange, { kind = 'add_child', child = item }),
    }))
    :map(function() return view_of(item) end)
end

local function claim_tree_op(store, custodian, child, authority, reason)
  return machine_op(store, child, NodeChange, {
    kind = 'acquire_member', item = child, custodian = custodian,
    authority = authority, reason = reason,
  }):and_then(Op.guard(function(snapshot)
    return store:children_op(child):and_then(Op.guard(function(children)
      local branches = {}
      for i = 1, #children do
        branches[i] = claim_tree_op(store, child, node_of(children[i]), authority, reason)
      end
      local descendants = #branches > 0 and Op.each(branches) or Op.always({})
      return descendants:map(function(rows)
        local claimed = {}
        if #branches > 0 then
          for i = 1, #branches do claimed[i] = rows[i][1] end
        end
        snapshot.children = claimed
        return snapshot
      end)
    end))
  end))
end

local function claim_children_op(store, custodian, authority, reason)
  return store:children_op(custodian):and_then(Op.guard(function(children)
    local branches = {}
    for i = 1, #children do
      branches[i] = claim_tree_op(store, custodian, node_of(children[i]), authority, reason)
    end
    if #branches == 0 then return Op.always({}) end
    return Op.each(branches):map(function(rows)
      local trees = {}
      for i = 1, #branches do trees[i] = rows[i][1] end
      return trees
    end)
  end))
end

local function walk_claim_tree(entry, fn)
  fn(entry)
  for i = 1, #(entry.children or {}) do walk_claim_tree(entry.children[i], fn) end
end

local function claim_entries(claim)
  local entries = {}
  local trees = claim.mode == 'subtree' and { claim.tree } or (claim.trees or {})
  for i = 1, #trees do
    walk_claim_tree(trees[i], function(entry) entries[#entries + 1] = entry end)
  end
  return entries
end

local function close_claim(mode, custodian, subject, authority, tree_or_trees, purpose, reason)
  local claim = {
    _fibers_close_claim = true,
    _fibers_value = true,
    mode = mode,
    authority = authority,
    custodian = custodian,
    subject = subject,
    purpose = purpose,
    reason = reason,
  }
  if mode == 'subtree' then claim.tree = tree_or_trees else claim.trees = tree_or_trees end
  local member_set = {}
  local entries = claim_entries(claim)
  for i = 1, #entries do member_set[entries[i].node] = true end
  claim.member_set = member_set
  return claim
end

local function find_existing_claim_op(store, custodian)
  return store:children_op(custodian):and_then(Op.guard(function(children)
    local function scan(i)
      if i > #children then return Op.always(nil) end
      local child = node_of(children[i])
      return machine_op(store, child, NodeQuery, { kind = 'close_claim' }):and_then(Op.guard(function(authority, fault)
        -- Only a retained failed claim delegates recovery authority. An active
        -- process is ordinary concurrent progress: an overlapping claim waits
        -- transactionally for it to discharge, then retries against fresh custody.
        if authority ~= nil and fault ~= nil then
          return Op.always({ node = child, authority = authority, fault = fault })
        end
        return find_existing_claim_op(store, child):and_then(Op.guard(function(found)
          return found and Op.always(found) or scan(i + 1)
        end))
      end))
    end
    return scan(1)
  end))
end

function Store:_acquire_close_claim_op(view, item, purpose)
  item = node_of(item)
  local custodian, store = custodian_of(view), self
  local authority = { _fibers_close_authority = true }
  local reason = type(purpose) == 'table' and purpose.reason or nil
  local retired = { _fibers_value = true, _fibers_already_retired = true, item = view_of(item) }

  return machine_op(self, item, NodeChange, {
    kind = 'claim_subject', item = item, custodian = custodian,
    authority = authority, reason = reason, already_retired = retired,
    delegate_existing = type(purpose) == 'table' and purpose.delegate_existing == true,
  }):and_then(Op.guard(function(snapshot)
    if type(snapshot) == 'table' and (snapshot._fibers_already_retired or snapshot._fibers_close_delegated) then
      return Op.always(snapshot)
    end
    return claim_children_op(store, item, authority, reason):map(function(children)
      snapshot.children = children
      return close_claim('subtree', custodian, item, authority, snapshot, purpose, reason)
    end)
  end))
end

-- Claim every current descendant of a Scope without claiming or retiring the
-- Scope itself. Any overlapping in-flight/failed descendant claim delegates the
-- structural responsibility to the existing process rather than competing.
function Store:_acquire_descendants_claim_op(view, purpose)
  local custodian, store = custodian_of(view), self
  local authority = { _fibers_close_authority = true }
  local reason = type(purpose) == 'table' and purpose.reason or nil
  local retired = { _fibers_value = true, _fibers_already_retired = true, item = view_of(custodian) }

  return find_existing_claim_op(store, custodian):and_then(Op.guard(function(retained)
    if retained then
      return Op.always({ _fibers_value = true, _fibers_close_delegated = true, retained = retained })
    end
    return machine_op(self, custodian, NodeChange, {
      kind = 'claim_descendants', authority = authority,
      reason = reason, already_retired = retired,
    })
  end)):and_then(Op.guard(function(acquired)
    if type(acquired) == 'table' and (acquired._fibers_close_delegated or acquired._fibers_already_retired) then
      return Op.always(acquired)
    end
    return claim_children_op(store, custodian, authority, reason):map(function(trees)
      return close_claim('descendants', custodian, custodian, authority, trees, purpose, reason)
    end)
  end))
end

local function containment_op(store, claim)
  local entries = claim_entries(claim)
  local operations = {}
  for i = 1, #entries do
    local entry = entries[i]
    local containment = machine_op(store, entry.node, NodeQuery, {
      kind = 'claim_containment', custodian = entry.custodian,
      authority = claim.authority, claim = claim,
    })
    local scope_role = entry.node:_scope_role(false)
    local scope_result = scope_role and scope_role.result
    if scope_result then
      containment = containment:and_then(Op.guard(function(count, err)
        return scope_result:success_op():map(function(settlement)
          return count, err, settlement
        end)
      end))
    end
    operations[i] = containment
  end
  if #operations == 0 then return Op.always({}, {}) end
  return Op.each(operations):map(function(rows)
    local blockers, settlements = {}, {}
    for i = 1, #entries do
      local count, err, settlement = rows[i][1], rows[i][2], rows[i][3]
      local node = entries[i].node
      if settlement ~= nil then settlements[node] = settlement end
      if (count or 0) > 0 then
        blockers[#blockers + 1] = { node = node, item = view_of(node), count = count, error = err }
      end
    end
    return blockers, settlements
  end)
end

local function children_by_custodian(claim)
  local children = {}
  local entries = claim_entries(claim)
  for i = 1, #entries do
    local entry = entries[i]
    if claim.mode == 'descendants' or entry.node ~= claim.subject then
      local list = children[entry.custodian] or {}
      list[#list + 1] = entry.node
      children[entry.custodian] = list
    end
  end
  return children, entries
end

local function claim_host(claim)
  return claim.mode == 'descendants' and claim.custodian or claim.subject
end

function Store:_restart_close_claim_op(claim, failure)
  if not is_close_claim(claim) then return Op.never() end
  local entries = claim_entries(claim)
  local operations = {
    machine_op(self, claim_host(claim), NodeChange, {
      kind = 'restart_claim', authority = claim.authority, failure = failure,
    }),
  }
  -- Failure details attached to individual Lifetimes are diagnostic mirrors of
  -- the retained claim. Clear them in the same restart transaction.
  for i = 1, #entries do
    local entry = entries[i]
    if entry.node ~= claim_host(claim) then
      operations[#operations + 1] = machine_op(self, entry.node, NodeChange, {
        kind = 'restart_member', custodian = entry.custodian, authority = claim.authority,
      })
    end
  end
  return Op.each(operations):map(function() return claim end)
end

function Store:_fail_close_claim_op(claim, failure)
  if not is_close_claim(claim) then return Op.never() end
  local entries = claim_entries(claim)
  local progress = {}
  local process = type(failure) == 'table' and failure._process
  for i = 1, #((process and process._progress) or {}) do
    local row = process._progress[i]
    progress[row.node] = row
  end
  local operations = {
    machine_op(self, claim_host(claim), NodeChange, {
      kind = 'fail_claim', authority = claim.authority, failure = failure,
    }),
  }
  for i = 1, #entries do
    local entry = entries[i]
    if entry.node ~= claim_host(claim) then
      operations[#operations + 1] = machine_op(self, entry.node, NodeChange, {
        kind = 'fail_member', custodian = entry.custodian, authority = claim.authority,
        reason = claim.reason, progress = progress[entry.node], first_error = failure and failure.error,
      })
    end
  end
  return Op.each(operations):map(function() return claim end)
end

function Store:_discharge_close_claim_op(claim)
  if not is_close_claim(claim) or not claim.custodian or not claim.subject then return Op.never() end
  local custodian = claim.custodian
  return containment_op(self, claim):and_then(Op.guard(function(blockers, settlements)
    if #blockers > 0 then return Op.always(false, blockers) end
    local children, entries = children_by_custodian(claim)
    local top_children = children[claim.subject] or {}
    local operations
    if claim.mode == 'descendants' then
      operations = { machine_op(self, custodian, NodeChange, {
        kind = 'release_descendants_claim', authority = claim.authority, children = top_children,
      }) }
    else
      operations = { machine_op(self, custodian, NodeChange, { kind = 'remove_child', child = claim.subject }) }
    end
    for i = 1, #entries do
      local entry = entries[i]
      operations[#operations + 1] = machine_op(self, entry.node, NodeChange, {
        kind = 'discharge_member', custodian = entry.custodian,
        authority = claim.authority, reason = claim.reason, children = children[entry.node],
      })
    end
    local outcome_ops = {}
    for i = 1, #entries do
      local node = entries[i].node
      local settlement = settlements and settlements[node] or nil
      if settlement ~= nil and node._outcome and node._outcome:_is_pending() then
        outcome_ops[#outcome_ops + 1] = node:_publish_outcome_op(settlement)
      end
    end
    local publish = #outcome_ops > 0 and Op.each(outcome_ops) or Op.always(true)
    return Op.each(operations)
      :and_then(publish)
      :map(function() return true, view_of(claim.subject) end)
  end))
end


function Store:request_cancel_op(value, reason)
  return machine_op(self, node_of(value), NodeChange, { kind = 'request_cancel', reason = reason })
    :or_else(Op.always(false, reason))
end

function Store:cancel_requested_op(value)
  return machine_op(self, node_of(value), NodeQuery, { kind = 'cancel_requested' })
end

function Store:close_requested_op(value)
  return machine_op(self, node_of(value), NodeQuery, { kind = 'close_requested' })
end

function Store:retired_op(value)
  return machine_op(self, node_of(value), NodeQuery, { kind = 'retired' })
end

function Store:_close_requested(value)
  local node = node_of(value)
  if not node then return false end
  self:attach_node(node)
  local state = node._lifetime_location.value
  return state.close_request ~= nil or state.phase == 'retired', close_reason(state)
end

function Store:request_close_op(value, reason)
  return machine_op(self, node_of(value), NodeChange, { kind = 'request_close', reason = reason })
    :or_else(Op.always(false, reason))
end

function Store:record_closure_fault_op(value, err, reason)
  return machine_op(self, node_of(value), NodeChange, { kind = 'record_fault', reason = reason, err = err })
    :or_else(Op.always(false, reason))
end

function Store:seal_op(view)
  return machine_op(self, custodian_of(view), NodeChange, { kind = 'seal' })
end

function Store:has_custody_op(view, item)
  local node = node_of(item)
  return machine_op(self, node, NodeQuery, { kind = 'has_custody', custodian = custodian_of(view), item = node })
end

function Store:children_op(view)
  return machine_op(self, custodian_of(view), NodeQuery, { kind = 'children' })
end

function Store:sealed_op(view)
  return machine_op(self, custodian_of(view), NodeQuery, { kind = 'sealed' })
end

function Store:active_op(item)
  local node = node_of(item)
  return machine_op(self, node, NodeQuery, { kind = 'active', item = node })
end

function Store:custody_can_op(view, item, right, opts)
  local node = node_of(item)
  return machine_op(self, node, NodeQuery, {
    kind = 'authorise', custodian = custodian_of(view), item = node, right = right,
    allow_closing = opts and opts.allow_closing == true,
  })
end

function Store:grant_can_op(view, item, right)
  local subject = assert(node_of(item), 'Grant subject must carry a Lifetime')
  return Op.each({ self:active_op(subject), self:children_op(view) }):and_then(Op.guard(function(rows)
    if not rows[1][1] then return Op.never() end
    local children = rows[2][1]
    local function scan(i)
      local grant = children[i]
      if not grant then return Op.never() end
      if not (Grant.is(grant) and Grant._subject_lifetime(grant) == subject and grant:has_right(right)) then
        return scan(i + 1)
      end
      return self:custody_can_op(view, grant):and_then(Op.guard(function(ok)
        return ok and Op.always(item, { kind = 'grant', grant = grant, right = right }) or scan(i + 1)
      end))
    end
    return scan(1)
  end))
end


function Store:_custodian(value)
  local node = node_of(value)
  if not node then return nil end
  self:attach_node(node)
  local state = node._lifetime_location.value
  return is_owned(state) and state.custodian or nil
end

function Store:_phase(value)
  local node = node_of(value)
  if not node then return 'dormant' end
  self:attach_node(node)
  return node._lifetime_location.value.phase
end

function Store:_lifecycle(value)
  local node = node_of(value)
  if not node then return 'dormant', nil, nil end
  self:attach_node(node)
  local state = node._lifetime_location.value
  return state.phase, close_reason(state), state.closure_fault
end

function Store:_children(view)
  local node = custodian_of(view)
  self:attach_node(node)
  return copy_list(node._lifetime_location.value.children)
end

return Store

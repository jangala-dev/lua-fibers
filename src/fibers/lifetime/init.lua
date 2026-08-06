-- Lifetime: one continuing consequence under custody of a committed operation.
--
-- A Lifetime node is the sole identity used by the runtime-local custody
-- store. Task, Scope and domain objects are capability views which carry a
-- reference to a node. Dormant topology exists only during construction; once
-- admitted, the Runtime-local LifetimeStore is the sole source of live
-- parentage, children, custody phase and closure progress.

local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local Cell = require('fibers.resource.cell')
local StateMachine = require('fibers.resource.machine')
local Effect = require('fibers.effect')
local Label = require('fibers.internal.label')

local Lifetime = {}
Lifetime.CloseReason = { NORMAL = 'normal' }
local Node = {}

Node.__index = Node

local RequestCancel = StateMachine.update('lifetime.request_cancel', function(state, payload)
  if type(state) == 'table' and (state.cancelled or state.requested) then
    return StateMachine.Ready.same(false, state.reason)
  end
  local next_state = {
    requested = true,
    cancelled = true,
    reason = payload.reason,
  }
  return StateMachine.Ready.write(next_state, true, payload.reason)
end)

local function pending()
  return { status = 'pending' }
end

local function is_done(value)
  return type(value) == 'table' and value.status == 'done'
end

local function wait_for(cell, pred)
  return Cell.wait_until_op(cell, pred)
end

local function initial_closure_state()
  return { processed = {}, child_exits = {}, child_failures = {}, sequence = 0 }
end

local function copy_list(xs)
  local out = {}
  for i = 1, #(xs or {}) do out[i] = xs[i] end
  return out
end

-- Dormant topology is ordinary Lua data, so validate it explicitly before it
-- can reach recursive binding or the transactional store. The root may carry a
-- construction parent used by Scope views; only edges traversed below the root
-- form the structural subtree being admitted.
local function walk_construction_tree(root, visit)
  local seen, active = {}, {}

  local function walk(node, parent)
    if active[node] then
      error('Lifetime structural children must form an acyclic tree', 3)
    end
    if seen[node] then
      error('Lifetime structural child appears more than once', 3)
    end
    if parent ~= nil and node._construction_parent ~= parent then
      error('Lifetime structural parent/child links are inconsistent', 3)
    end

    seen[node], active[node] = true, true
    if visit then visit(node, parent) end
    local children = node._construction_children or {}
    for i = 1, #children do
      local child = children[i]
      if not Lifetime.is(child) then
        error('Lifetime structural child is not a Lifetime', 3)
      end
      walk(child, node)
    end
    active[node] = nil
  end

  walk(root, nil)
  return seen
end

local function normalise_closure(protocol, label)
  return require('fibers.closure').protocol(protocol, label)
end

local function node_of(value)
  if Lifetime.is(value) then return value end
  return type(value) == 'table' and Lifetime.is(value._lifetime) and value._lifetime or nil
end

local function node_for(value, level)
  local node = node_of(value)
  if node then return node end
  error('expected a Lifetime or a value carrying a Lifetime', level or 3)
end

function Lifetime.new(opts)
  opts = opts or {}
  if type(opts) ~= 'table' then
    error('Lifetime.new expects an options table or nil', 2)
  end
  local node_kind = 'lifetime'
  local node = setmetatable({
    _fibers_lifetime = true,
    _construction_parent = opts.parent and node_for(opts.parent, 3) or nil,
    _construction_children = {},
    _admitted = false,
    value = opts.value,
    standalone_boundary = opts.standalone_boundary == true,
    body = opts.body,
    has_body = opts.body ~= nil,
    closure = normalise_closure(opts.closure, node_kind .. ' closure'),
    role = opts.role,
    rights = opts.rights,
    meta = opts.meta,
    cancellation = opts.cancellation
      or StateMachine.new({ requested = false, cancelled = false }):label(node_kind .. '-cancellation'),
    interrupt = opts.interrupt or Runtime._new_interrupt(node_kind .. '-interrupt'),
    body_result = opts.body_result or Cell.new(pending()):label(node_kind .. '-body-result'),
    outcome = opts.outcome or Cell.new(pending()):label(node_kind .. '-outcome'),
    closure_state = opts.closure_state or initial_closure_state(),
    offers = opts.offers,
  }, Node)
  Label.attach(node)
  if opts.label ~= nil then Label.set(node, opts.label, 2) end
  Label.child(node.cancellation, node, 'cancellation')
  Label.child(node.body_result, node, 'body-result')
  Label.child(node.outcome, node, 'outcome')
  if type(node.offers) == 'table' then Label.child(node.offers, node, 'offers') end

  -- The dependency index uses this marker to connect an observer of a
  -- Lifetime's terminal outcome to the currently pending operations which can
  -- make that outcome true.  This is a directional causal edge, not a
  -- transactional data dependency: producers in the same Scope do not become
  -- mutually dependent unless an outcome observer is present.
  node.outcome._location._fibers_completion_lifetime = node

  if node.value ~= nil then
    if type(node.value) ~= 'table' then
      error('a Lifetime domain value must be a table', 2)
    end
    if node.value._lifetime and node.value._lifetime ~= node then
      error('domain value already belongs to another Lifetime', 2)
    end
    node.value._lifetime = node
  end
  for i = 1, #(opts.children or {}) do
    node:add_child(opts.children[i])
  end
  if opts.runtime then node:bind_runtime(opts.runtime) end
  return node
end

function Node:label(...)
  if select('#', ...) == 0 then
    return Label.get(self)
  end
  Label.set(self, select(1, ...), 2)
  return self
end

function Node:diagnostic_label()
  return Label.describe(self, self._fibers_id or 'lifetime')
end

function Lifetime.is(value)
  return type(value) == 'table' and value._fibers_lifetime == true
end

function Lifetime.of(value)
  return node_of(value)
end

function Lifetime.require(value, level)
  return node_for(value, level or 3)
end

-- Mark a transactional state location as an observable consequence of a
-- Lifetime's running body.  Component arbitration uses this directional causal
-- relation to let the responsible body make progress before an observer takes a
-- certified fallback.  It does not merge unrelated producer requests.
function Lifetime._mark_causal_state(value, state)
  local node = node_for(value, 3)
  local location = state and state._location
  if not location then
    error('Lifetime causal state must expose a transactional location', 2)
  end
  location._fibers_causal_lifetime = node
  return state
end

-- Attach exactly one dormant Lifetime to a domain value. Definitions are
-- deliberately one-shot: silently adding body, closure or children to an
-- existing node made construction order part of the API and obscured mistakes.
function Lifetime.define(value, opts)
  if type(value) ~= 'table' then
    error('Lifetime.define expects a table value', 2)
  end
  if Lifetime.of(value) then
    error('value already carries a Lifetime', 2)
  end
  opts = opts or {}
  local node = Lifetime.new({
    value = value,
    body = opts.body,
    closure = opts.closure,
    role = opts.role,
    rights = opts.rights,
    meta = opts.meta,
    children = opts.children,
    label = opts.label,
  })
  Label.proxy(value, node)
  return value
end

function Lifetime.inert(value, opts)
  return Lifetime.define(value, opts)
end

function Lifetime.task(body, opts)
  if type(body) ~= 'function' then error('Lifetime.task expects a function', 2) end
  opts = opts or {}
  return Lifetime.new({
    body = body,
    closure = opts.closure,
    role = opts.role or 'task',
    label = opts.label,
  })
end

function Lifetime.resource(value, opts)
  return Lifetime.define(value, opts)
end

function Node:add_child(value)
  if self._admitted or self.runtime ~= nil then
    error('children may only be added before a Lifetime is bound or admitted', 2)
  end
  local child = Lifetime.of(value)
  if not child then
    error('Lifetime:add_child expects a Lifetime or a value carrying one; use Lifetime.inert explicitly', 2)
  end
  if child == self then error('a Lifetime cannot own itself', 2) end
  local ancestor = self
  while ancestor do
    if ancestor == child then
      error('Lifetime structural children must form an acyclic tree', 2)
    end
    ancestor = ancestor._construction_parent
  end
  if child.runtime ~= nil or child._admitted then
    error('a live or bound Lifetime cannot become a dormant structural child', 2)
  end
  if child._construction_parent and child._construction_parent ~= self then
    error('Lifetime child already has a structural parent', 2)
  end
  for i = 1, #self._construction_children do
    if self._construction_children[i] == child then return child end
  end
  child._construction_parent = self
  self._construction_children[#self._construction_children + 1] = child
  return child
end

function Node:_construction_parent_node()
  return self._construction_parent
end

function Node:_on_admitted()
  self._admitted = true
  self._terminal_phase = nil
  self._terminal_reason = nil
  self._construction_parent = nil
  self._construction_children = nil
end

function Node:_on_retired(reason)
  self._admitted = false
  self._terminal_phase = 'closed'
  self._terminal_reason = reason
end

function Node:assert_runtime_compatible(runtime)
  if type(runtime) ~= 'table' or type(runtime._lifetime_store) ~= 'function' then
    error('Lifetime runtime compatibility requires a Runtime', 2)
  end
  runtime:_lifetime_store()
  walk_construction_tree(self, function(node)
    if node.runtime and node.runtime ~= runtime then
      error('Lifetime already belongs to another Runtime', 3)
    end
  end)
  return true
end

-- Commit-local binding installs runtime identity without opening a boundary by
-- ordinary mutation. Admission has already installed the boundary state in the
-- transactional LifetimeStore before this hook runs.
function Node:_bind_runtime_committed(runtime)
  if self.runtime and self.runtime ~= runtime then
    error('Lifetime already belongs to another Runtime', 2)
  end
  self.runtime = runtime
  runtime:_lifetime_store():attach_boundary(self)
  return self
end

function Node:bind_runtime(runtime)
  self:assert_runtime_compatible(runtime)

  -- Explicit binding remains an immediate operation used for active roots and
  -- host-created boundaries. Admission uses _bind_runtime_committed only after
  -- the managed-state transition has committed.
  walk_construction_tree(self, function(node)
    node:_bind_runtime_committed(runtime)
    if node.standalone_boundary then runtime:_lifetime_store():activate_boundary(node) end
  end)
  return self
end

function Node:record_map()
  if self._admitted then error('cannot reconstruct records for an admitted Lifetime', 2) end
  local out = {}
  walk_construction_tree(self, function(node, parent)
    local rec = {
      node = node,
      lifetime = node,
      closure = node.closure,
      role = node.role,
      parent = parent,
      children = {},
      phase = 'live',
      rights = node.rights,
      meta = node.meta,
    }
    out[node] = rec
    if parent ~= nil then
      out[parent].children[#out[parent].children + 1] = node
    end
  end)
  return out
end

function Node:current_state()
  if self.runtime then
    local state = self.runtime:_lifetime_store():current_state(self)
    if state then return state end
  end
  return {
    lifetime = self,
    custody_phase = nil,
    closure_phase = self._terminal_phase or 'dormant',
    closure_reason = self._terminal_reason,
    custodian = nil,
    parent = self._construction_parent,
    children = copy_list(self._construction_children),
    closure_progress = nil,
  }
end

function Node:closed_op()
  local node = self
  local function wait()
    if not node.runtime then
      local phase = node._terminal_phase or 'dormant'
      return phase == 'closed' and Op.always(node) or Op.never()
    end
    return node.runtime:_lifetime_store():node_state_op(node):and_then(Op.guard(function(state)
      if state.closure_phase == 'closed' then return Op.always(node) end
      return node.runtime:_lifetime_store():changed_op(node, state.version):and_then(
        Op.guard(function(...)
          return wait(...)
        end)
      )
    end))
  end
  return wait()
end

function Node:request_close_op(reason)
  if not self.runtime then
    return Op.always(false, self._terminal_reason or reason)
  end
  return self.runtime:_lifetime_store():request_close_op(self, reason)
end

function Node:_closing_op(reason)
  if not self.runtime then error('cannot mark an unbound Lifetime closing', 2) end
  return self.runtime:_lifetime_store():mark_closing_op(self, reason)
end

function Node:_mark_closure_failed_op(err, reason)
  if not self.runtime then error('cannot fail an unbound Lifetime', 2) end
  return self.runtime:_lifetime_store():mark_closure_failed_op(self, err, reason)
end

function Node:_mark_closed_op(reason)
  if not self.runtime then
    self:_on_retired(reason)
    return Op.always(true)
  end
  return self.runtime:_lifetime_store():mark_closed_op(self, reason)
end

function Node:request_cancel_op(reason)
  local node = self
  local close_op = self:request_close_op(reason)
  return close_op:and_then(node.cancellation
      :transition_op(RequestCancel, { reason = reason })
      :and_then(Op.guard(function(first, recorded_reason)
        if not first then return Op.always(false, recorded_reason) end
        return Op.emit(Effect.interrupt(node.interrupt, recorded_reason)):map(function()
          return true, recorded_reason
        end)
      end)))
end

function Node:cancel_requested_op()
  return wait_for(self.cancellation, function(value)
    return type(value) == 'table' and (value.requested or value.cancelled)
  end):map(function(value)
    return true, value.reason
  end)
end

function Node:cancellation_op()
  return self.cancellation:read_op()
end

local function publish_once_op(cell, result)
  return cell:read_op():and_then(Op.guard(function(value)
    if is_done(value) then return Op.always(false, value.result) end
    return cell:write_op({ status = 'done', result = result }):map(function()
      return true, result
    end)
  end))
end

local function completed_op(cell)
  return wait_for(cell, is_done):map(function(value) return value.result end)
end

function Node:publish_body_result_op(result)
  return publish_once_op(self.body_result, result)
end

function Node:body_result_op()
  return completed_op(self.body_result)
end

function Node:publish_outcome_op(result)
  return publish_once_op(self.outcome, result)
end

function Node:outcome_op()
  return completed_op(self.outcome)
end

function Node:inspect_op()
  local cancellation = self.cancellation:read_op()
  local body_result = self.body_result:read_op()
  local outcome = self.outcome:read_op()
  local topology = self.runtime and self.runtime:_lifetime_store():node_state_op(self) or Op.always(self:current_state())
  return topology:and_then(Op.guard(function(state)
    return cancellation:and_then(Op.guard(function(cancel)
      return body_result:and_then(Op.guard(function(body)
        return outcome:map(function(boundary)
          return {
            lifetime = self,
            label = Label.describe(self, self._fibers_id or 'lifetime'),
            phase = state.closure_phase,
            custody_phase = state.custody_phase,
            custodian = state.custodian,
            parent = state.parent,
            children = state.children,
            closure_progress = state.closure_progress,
            cancellation = cancel,
            body_result = body,
            outcome = boundary,
          }
        end)
      end))
    end))
  end))
end

Lifetime.Node = Node
return Lifetime

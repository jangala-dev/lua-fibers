-- Lifetime: one continuing consequence under custody of a committed operation.
--
-- A Lifetime node is the sole identity used by the runtime-local custody
-- store. Task, Scope and domain objects are capability views which carry a
-- reference to a node. Dormant topology exists only during construction; once
-- admitted, the Runtime-local LifetimeStore is the sole source of live
-- parentage, children, custody phase and closure progress.

local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local Scalar = require('fibers.resource.scalar')
local Effect = require('fibers.effect')

local Lifetime = {}
Lifetime.CloseReason = { NORMAL = 'normal' }
local Node = {}

Node.__index = Node

local RequestCancel = Scalar.transition({
  name = 'lifetime.request_cancel',
  mode = 'update',
  accepts_supply = true,
  supplies = 'any',
  step = function(state, payload)
    if type(state) == 'table' and (state.cancelled or state.requested) then
      return Scalar.Ready.same(false, state.reason)
    end
    local next_state = {
      requested = true,
      cancelled = true,
      reason = payload.reason,
    }
    return Scalar.Ready.write(next_state, true, payload.reason)
  end,
})

local function pending()
  return { status = 'pending' }
end

local function is_done(value)
  return type(value) == 'table' and value.status == 'done'
end

local function wait_for(scalar, pred)
  return Scalar.value_op(scalar, pred)
end

local function initial_closure_state()
  return { processed = {}, child_exits = {}, child_failures = {}, sequence = 0 }
end

local function copy_list(xs)
  local out = {}
  for i = 1, #(xs or {}) do
    out[i] = xs[i]
  end
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
    if visit then
      visit(node, parent)
    end
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
  return require('fibers.closure').normalize(protocol, label)
end

local function node_of(value)
  if Lifetime.is(value) then
    return value
  end
  return type(value) == 'table' and Lifetime.is(value._lifetime) and value._lifetime or nil
end

local function node_for(value, level)
  local node = node_of(value)
  if node then
    return node
  end
  error('expected a Lifetime or a value carrying a Lifetime', level or 3)
end

function Lifetime.new(name, opts)
  opts = opts or {}
  local node_name = name or 'lifetime'
  local node = setmetatable({
    _fibers_lifetime = true,
    _construction_parent = opts.parent and node_for(opts.parent, 3) or nil,
    _construction_children = {},
    _admitted = false,
    name = node_name,
    value = opts.value,
    standalone_boundary = opts.standalone_boundary == true,
    body = opts.body,
    has_body = opts.body ~= nil,
    closure = normalise_closure(opts.closure, node_name .. ' closure'),
    role = opts.role,
    rights = opts.rights,
    meta = opts.meta,
    cancellation = opts.cancellation
      or Scalar.new({ requested = false, cancelled = false }, node_name .. '-cancellation'),
    interrupt = opts.interrupt or Runtime._new_interrupt(node_name .. '-interrupt'),
    body_result = opts.body_result or Scalar.new(pending(), node_name .. '-body-result'),
    outcome = opts.outcome or Scalar.new(pending(), node_name .. '-outcome'),
    closure_state = opts.closure_state or initial_closure_state(),
    offers = opts.offers,
  }, Node)
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
  if opts.runtime then
    node:bind_runtime(opts.runtime)
  end
  return node
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
  Lifetime.new(opts.name or value.name, {
    value = value,
    body = opts.body,
    closure = opts.closure,
    role = opts.role,
    rights = opts.rights,
    meta = opts.meta,
    children = opts.children,
  })
  return value
end

function Lifetime.inert(value, opts)
  return Lifetime.define(value, opts)
end

function Lifetime.task(body, opts)
  if type(body) ~= 'function' then
    error('Lifetime.task expects a function', 2)
  end
  opts = opts or {}
  return Lifetime.new(opts.name, {
    body = body,
    closure = opts.closure,
    role = opts.role or 'task',
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
  if child == self then
    error('a Lifetime cannot own itself', 2)
  end
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
    if self._construction_children[i] == child then
      return child
    end
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

function Node:bind_runtime(runtime)
  if type(runtime) ~= 'table' or not runtime.lifetimes then
    error('Lifetime:bind_runtime expects a Runtime with a LifetimeStore', 2)
  end

  -- Validate the complete dormant graph before mutating any node. This avoids
  -- partial binding if a malformed raw graph contains a late cycle or shared
  -- descendant.
  walk_construction_tree(self, function(node)
    if node.runtime and node.runtime ~= runtime then
      error('Lifetime already belongs to another Runtime', 3)
    end
  end)
  walk_construction_tree(self, function(node)
    node.runtime = runtime
    runtime.lifetimes:attach_boundary(node, node.name)
    if node.standalone_boundary then
      runtime.lifetimes:activate_boundary(node)
    end
  end)
  return self
end

function Node:record_map()
  if self._admitted then
    error('cannot reconstruct records for an admitted Lifetime', 2)
  end
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
  if self.runtime and self.runtime.lifetimes then
    local state = self.runtime.lifetimes:current_state(self)
    if state then
      return state
    end
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
    return node.runtime.lifetimes:node_state_op(node):and_then(function(state)
      if state.closure_phase == 'closed' then
        return Op.always(node)
      end
      return node.runtime.lifetimes:changed_op(node, state.version):and_then(wait)
    end)
  end
  return wait()
end

function Node:request_close_op(reason)
  if not self.runtime then
    return Op.always(false, self._terminal_reason or reason)
  end
  return self.runtime.lifetimes:request_close_op(self, reason)
end

function Node:_closing_op(reason)
  if not self.runtime then
    error('cannot mark an unbound Lifetime closing', 2)
  end
  return self.runtime.lifetimes:mark_closing_op(self, reason)
end

function Node:_mark_closure_failed_op(err, reason)
  if not self.runtime then
    error('cannot fail an unbound Lifetime', 2)
  end
  return self.runtime.lifetimes:mark_closure_failed_op(self, err, reason)
end

function Node:_mark_closed_op(reason)
  if not self.runtime then
    self:_on_retired(reason)
    return Op.always(true)
  end
  return self.runtime.lifetimes:mark_closed_op(self, reason)
end

function Node:request_cancel_op(reason)
  local node = self
  local close_op = self:request_close_op(reason)
  return close_op:and_then(function()
    return node.cancellation
      :transition_op(RequestCancel, { reason = reason })
      :and_then(function(first, recorded_reason)
        if not first then
          return Op.always(false, recorded_reason)
        end
        return Op.emit(Effect.interrupt(node.interrupt, recorded_reason)):map(function()
          return true, recorded_reason
        end)
      end, false)
  end)
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

local function publish_once_op(scalar, result)
  return scalar:read_op():and_then(function(value)
    if is_done(value) then
      return Op.always(false, value.result)
    end
    return scalar:write_op({ status = 'done', result = result }):map(function()
      return true, result
    end)
  end)
end

local function completed_op(scalar)
  return wait_for(scalar, is_done):map(function(value)
    return value.result
  end)
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
  local topology = self.runtime and self.runtime.lifetimes:node_state_op(self)
    or Op.always(self:current_state())
  return topology:and_then(function(state)
    return cancellation:and_then(function(cancel)
      return body_result:and_then(function(body)
        return outcome:map(function(boundary)
          return {
            lifetime = self,
            name = self.name,
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
      end, Op.dependencies(outcome))
    end, Op.dependencies(body_result, outcome))
  end, Op.dependencies(cancellation, body_result, outcome))
end

Lifetime.Node = Node
return Lifetime

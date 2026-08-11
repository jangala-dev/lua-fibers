-- Lifetime: one continuing consequence under custody of a committed operation.
--
-- A Lifetime node is the sole identity used by the runtime-local custody
-- store. Task, Scope and domain objects are capability views which carry a
-- reference to a node. Composite-resource construction plans exist only before
-- admission; once admitted, the Runtime-local LifetimeStore is the sole source
-- of live parentage, children, custody phase and closure progress.

local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local Completion = require('fibers.resource.completion')
local Effect = require('fibers.effect')
local Label = require('fibers.internal.label')
local Contract = require('fibers.internal.contract')

local Lifetime = {}
Lifetime.CloseReason = { NORMAL = 'normal' }
local Node = {}
local next_lifetime_id = 0

Node.__index = Node

-- Composite-resource topology before admission is ordinary construction data.
-- It is not a second live custody tree. The plan disappears when admission
-- commits and LifetimeStore becomes authoritative.
local function walk_construction_plan(root, visit, seen)
  seen = seen or {}
  if seen[root] then error('Lifetime construction children must form an acyclic tree', 3) end
  seen[root] = true
  if visit then visit(root) end
  local plan = root._construction
  for i = 1, #(plan and plan.children or {}) do
    walk_construction_plan(plan.children[i], visit, seen)
  end
  return seen
end

local function normalise_closure(value, label)
  return require('fibers.closure').protocol(value, label)
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

local LIFETIME_OPTIONS = {
  value = true, closure = true,
  role = true, rights = true, meta = true, label = true, children = true, runtime = true,
}
local DEFINE_OPTIONS = {
  closure = true, role = true, rights = true, meta = true, children = true, label = true,
}

function Lifetime.new(opts)
  opts = Contract.options(opts, LIFETIME_OPTIONS, 'Lifetime.new options', 2)
  if opts.children ~= nil then Contract.table(opts.children, 'Lifetime.new children', 2) end
  local node_kind = 'lifetime'
  local protocol = normalise_closure(opts.closure, node_kind .. ' closure')
  next_lifetime_id = next_lifetime_id + 1
  local node = setmetatable({
    _fibers_lifetime = true,
    _fibers_id = 'lifetime-' .. tostring(next_lifetime_id),
    _construction = { parent = nil, children = {} },
    _roles = {},
    _value = opts.value,
    _protocol = protocol,
    _role = opts.role,
    _rights = opts.rights,
    _meta = opts.meta,
    _interrupt = Runtime._new_interrupt(),
    _outcome = Completion.new():label(node_kind .. '-outcome'),
  }, Node)
  Label.attach(node)
  if opts.label ~= nil then Label.set(node, opts.label, 2) end
  Label.child(node._outcome, node, 'outcome')

  -- The dependency index uses this marker to connect an observer of a
  -- Lifetime's terminal outcome to the currently pending operations which can
  -- make that outcome true.  This is a directional causal edge, not a
  -- transactional data dependency: producers in the same Scope do not become
  -- mutually dependent unless an outcome observer is present.
  node._outcome._location._fibers_completion_lifetime = node

  if node._value ~= nil then
    if type(node._value) ~= 'table' then
      error('a Lifetime domain value must be a table', 2)
    end
    if node._value._lifetime and node._value._lifetime ~= node then
      error('domain value already belongs to another Lifetime', 2)
    end
    node._value._lifetime = node
  end
  for i = 1, #(opts.children or {}) do
    node:add_child(opts.children[i])
  end
  if opts.runtime then node:_bind_runtime(opts.runtime) end
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

-- Scope and Task are views over one Lifetime identity. Their bookkeeping is
-- grouped by role so generic Lifetime state does not accrete view-specific
-- fields. These helpers are private implementation hooks.
function Node:_scope_role(create)
  local role = self._roles.scope
  if role == nil and create then
    role = { policy = {} }
    self._roles.scope = role
  end
  return role
end

function Node:_task()
  return self._roles.task
end

function Node:_attach_task(task)
  if self._roles.task ~= nil then
    error('Lifetime already has a Task view', 2)
  end
  self._roles.task = task
  return task
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
  opts = Contract.options(opts, DEFINE_OPTIONS, 'Lifetime.define options', 2)
  local node = Lifetime.new({
    value = value,
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


function Node:add_child(value)
  if self._runtime ~= nil or self._construction == nil then
    error('children may only be added before a Lifetime is bound or admitted', 2)
  end
  local child = Lifetime.of(value)
  if not child then
    error('Lifetime:add_child expects a Lifetime or a value carrying one; use Lifetime.define explicitly', 2)
  end
  if child == self then error('a Lifetime cannot own itself', 2) end
  local ancestor = self
  while ancestor do
    if ancestor == child then
      error('Lifetime construction children must form an acyclic tree', 2)
    end
    local plan = ancestor._construction
    ancestor = plan and plan.parent or nil
  end
  if child._runtime ~= nil or child._construction == nil then
    error('a live or bound Lifetime cannot become a construction child', 2)
  end
  local child_plan = child._construction
  if child_plan.parent and child_plan.parent ~= self then
    error('Lifetime construction child already has a parent', 2)
  end
  local children = self._construction.children
  for i = 1, #children do
    if children[i] == child then
      error('Lifetime construction child is already attached to this parent', 2)
    end
  end
  child_plan.parent = self
  children[#children + 1] = child
  return child
end

function Node:_on_admitted()
  self._construction = nil
end

function Node:_activate_committed(runtime)
  local task = self:_task()
  if task and type(task._activate_committed) == 'function' then
    return task:_activate_committed(runtime)
  end
  return nil
end
function Node:_assert_runtime_compatible(runtime)
  if type(runtime) ~= 'table' or type(runtime._lifetime_store) ~= 'function' then
    error('Lifetime runtime compatibility requires a Runtime', 2)
  end
  runtime:_lifetime_store()
  walk_construction_plan(self, function(node)
    if node._runtime and node._runtime ~= runtime then
      error('Lifetime already belongs to another Runtime', 3)
    end
  end)
  return true
end

-- Commit-local binding installs runtime identity without creating custody by
-- ordinary mutation. Admission has already installed the live NodeState in the
-- transactional LifetimeStore before this hook runs.
function Node:_bind_runtime_committed(runtime)
  if self._runtime and self._runtime ~= runtime then
    error('Lifetime already belongs to another Runtime', 2)
  end
  self._runtime = runtime
  runtime:_lifetime_store():attach_node(self)
  return self
end

function Node:_bind_runtime(runtime)
  self:_assert_runtime_compatible(runtime)

  -- Explicit binding remains an immediate operation used for explicitly pre-bound host-created values. Admission uses _bind_runtime_committed only after
  -- the managed-state transition has committed.
  walk_construction_plan(self, function(node)
    node:_bind_runtime_committed(runtime)
  end)
  return self
end

function Node:_construction_children_snapshot()
  local plan = self._construction
  local out = {}
  for i = 1, #(plan and plan.children or {}) do out[i] = plan.children[i] end
  return out
end

function Node:retired_op()
  if not self._runtime then return Op.never() end
  return self._runtime:_lifetime_store():retired_op(self):map(function() return self end)
end

function Node:_close_requested()
  if not self._runtime then return false, nil end
  return self._runtime:_lifetime_store():_close_requested(self)
end

function Node:close_requested_op()
  if not self._runtime then return Op.never() end
  return self._runtime:_lifetime_store():close_requested_op(self)
end

function Node:request_close_op(reason)
  if not self._runtime then return Op.always(false, reason) end
  return self._runtime:_lifetime_store():request_close_op(self, reason)
end

function Node:_record_closure_fault_op(err, reason)
  if not self._runtime then error('cannot record a fault on an unbound Lifetime', 2) end
  return self._runtime:_lifetime_store():record_closure_fault_op(self, err, reason)
end

function Node:request_cancel_op(reason)
  local node = self
  if not self._runtime then return Op.always(false, reason) end
  return self._runtime:_lifetime_store():request_cancel_op(self, reason)
    :and_then(Op.guard(function(first, recorded_reason)
      if not first then return Op.always(false, recorded_reason) end
      return Op.emit(Effect.interrupt(node._interrupt, recorded_reason)):map(function()
        return true, recorded_reason
      end)
    end))
end

function Node:cancel_requested_op()
  if not self._runtime then return Op.never() end
  return self._runtime:_lifetime_store():cancel_requested_op(self)
end

local function publish_completion_once_op(completion, result, label)
  return completion:publish_success_op(result):and_then(Op.guard(function(first, conflict)
    if first ~= true then
      error((label or 'Lifetime result') .. ' already published: ' .. tostring(conflict), 3)
    end
    return Op.always(result)
  end))
end

function Node:_publish_outcome_op(result)
  return publish_completion_once_op(self._outcome, result, 'Lifetime outcome')
end

function Node:outcome_op()
  return self._outcome:success_op()
end


return Lifetime

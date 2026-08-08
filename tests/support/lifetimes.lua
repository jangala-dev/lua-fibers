-- Test constructors for the public Lifetime model.

local Lifetime = require('fibers.lifetime')
local Scope = require('fibers.scope')
local Closure = require('fibers.closure')

local M = {}

function M.scope(runtime, name, closure)
  return Scope.new( {
    runtime = runtime,
    closure = closure or Closure.nursery({ name = name or 'test-scope' }),
  }):label(name or 'test-scope')
end

function M.resource(name, closure, opts)
  opts = opts or {}
  local value = opts.value or { name = name or 'test-resource' }
  if closure then
    Lifetime.define(value, {
      label = name,
      closure = closure,
      rights = opts.rights,
      role = opts.role,
      children = opts.children,
    })
  else
    Lifetime.inert(value, {
      label = name,
      rights = opts.rights,
      role = opts.role,
      children = opts.children,
    })
  end
  return value
end

function M.node(value)
  return assert(Lifetime.of(value), 'value has no Lifetime')
end

local function copy_list(xs)
  local out = {}
  for i = 1, #(xs or {}) do out[i] = xs[i] end
  return out
end

-- Test-only direct observation of the runtime store. Public Lifetime state is
-- intentionally Option-based; tests use this helper only to assert topology
-- after a run has completed or before admission has begun.
function M.state(value)
  local node = M.node(value)
  local rec, boundary
  if node._runtime then
    local _, r, b = node._runtime:_lifetime_store():_node_parts(node)
    rec, boundary = r, b
  end
  return {
    custodian = rec and rec.custodian or nil,
    parent = rec and rec.parent or node._construction_parent,
    children = rec and copy_list(rec.children) or copy_list(node._construction_children),
    custody_phase = rec and rec.phase or nil,
    closure_phase = (boundary and boundary.closure_phase) or node._terminal_phase or 'dormant',
    closure_reason = (boundary and boundary.closure_reason) or node._terminal_reason,
    closure_error = boundary and boundary.closure_error or nil,
    sealed = boundary and boundary.sealed == true or false,
    version = boundary and boundary.version or 0,
  }
end

function M.roots(scope)
  local nodes, out = scope:_store():_roots(scope), {}
  for i = 1, #nodes do out[i] = nodes[i]._value or nodes[i] end
  return out
end

function M.record(scope, item)
  local node = M.node(item)
  local _, rec = scope:_store():_node_parts(node)
  if rec and rec.custodian == scope:lifetime() then return rec end
end

function M.boundary(scope)
  local _, _, boundary = scope:_store():_node_parts(scope:lifetime())
  return boundary
end

function M.closure_state(value)
  local node = M.node(value)
  return node and node._closure_state or nil
end

function M.interrupt(value)
  local node = M.node(value)
  return node and node._interrupt or nil
end

return M

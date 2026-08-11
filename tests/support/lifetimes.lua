-- Test constructors and direct inspection for the public Lifetime model.

local Lifetime = require('fibers.lifetime')
local Scope = require('fibers.scope')
local Closure = require('fibers.closure')

local M = {}

function M.scope(runtime, name, closure)
  return Scope.new({
    runtime = runtime,
    closure = closure or Closure.nursery({ name = name or 'test-scope' }),
  }):label(name or 'test-scope')
end

function M.resource(name, closure, opts)
  opts = opts or {}
  local value = opts.value or { name = name or 'test-resource' }
  Lifetime.define(value, {
    label = name,
    closure = closure,
    rights = opts.rights,
    role = opts.role,
    children = opts.children,
  })
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

-- Test-only direct observation. The Runtime-local NodeState is authoritative
-- after admission; construction-plan links exist only before binding.
local function node_state(node)
  return node._lifetime_location and node._lifetime_location.value or nil
end

function M.state(value)
  local node = M.node(value)
  local state = node_state(node)
  local phase = state and state.phase or 'dormant'
  local close_request = state and state.close_request or nil
  local construction = node._construction
  return {
    phase = phase,
    custodian = state and state.custodian or nil,
    construction_parent = construction and construction.parent or nil,
    children = copy_list(state and state.children or (construction and construction.children or nil)),
    close_request = close_request,
    close_reason = close_request and close_request.reason or nil,
    closure_fault = state and state.closure_fault or nil,
    close_claimed = state and state.close_claim ~= nil or false,
    sealed = state and state.sealed == true or false,
    version = node._lifetime_location and node._lifetime_location.version or 0,
  }
end

function M.children(scope)
  local nodes, out = scope:_store():_children(scope), {}
  for i = 1, #nodes do out[i] = nodes[i]._value or nodes[i] end
  return out
end

function M.custody_snapshot(scope, item)
  local node = M.node(item)
  local state = node_state(node)
  if state and state.custodian == scope:lifetime() then
    return {
      node = node, item = node._value or node, custodian = state.custodian,
      protocol = node._protocol, role = node._role, rights = node._rights, meta = node._meta,
      phase = state.phase, closure_fault = state.closure_fault,
    }
  end
end


function M.closure_state(value)
  local node = M.node(value)
  local role = node and node:_scope_role(false)
  return role and role.driver_state or nil
end

function M.interrupt(value)
  local node = M.node(value)
  return node and node._interrupt or nil
end

return M

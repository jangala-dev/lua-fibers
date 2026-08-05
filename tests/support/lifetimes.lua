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
      name = name,
      closure = closure,
      rights = opts.rights,
      role = opts.role,
      children = opts.children,
    })
  else
    Lifetime.inert(value, {
      name = name,
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

return M

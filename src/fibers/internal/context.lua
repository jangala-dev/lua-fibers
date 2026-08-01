-- Dynamic Fibers execution context.
--
-- This deliberately contains no scheduler or facility dependencies. Modules that
-- only need the current Runtime or Scope should depend on this boundary rather
-- than requiring fibers.runtime.

local Context = {}
local current_runtime = nil
local current_scope = nil
local current_token = nil

function Context.current_runtime()
  return current_runtime
end

function Context.current_scope()
  return current_scope
end

function Context.enter(runtime, scope)
  local token = {
    runtime = current_runtime,
    scope = current_scope,
    parent = current_token,
  }
  current_runtime, current_scope, current_token = runtime, scope, token
  return token
end

function Context.leave(token)
  if type(token) ~= 'table' or current_token ~= token then
    error('Fibers context token mismatch', 2)
  end
  current_runtime, current_scope, current_token = token.runtime, token.scope, token.parent
  return true
end

function Context.push_scope(runtime, scope)
  local fiber = runtime and runtime._current_fiber
  if not fiber then error('scope entry requires current fibre', 2) end
  local stack = fiber.scope_stack or {}
  fiber.scope_stack = stack
  stack[#stack + 1] = scope
  fiber.scope = scope
  current_scope = scope
  return { fiber = fiber, depth = #stack, scope = scope }
end

function Context.pop_scope(runtime, token)
  local fiber = runtime and runtime._current_fiber
  if not token or token.fiber ~= fiber then error('scope token mismatch', 2) end
  local stack = fiber.scope_stack or {}
  if #stack ~= token.depth or stack[#stack] ~= token.scope then error('scope stack mismatch', 2) end
  stack[#stack] = nil
  fiber.scope = stack[#stack]
  current_scope = fiber.scope
  return true
end

function Context.set_scope(scope)
  current_scope = scope
  return scope
end

return Context

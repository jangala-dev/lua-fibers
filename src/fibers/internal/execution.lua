-- Dynamic execution contracts for the currently resumed runtime fiber.
--
-- This is deliberately small. Public APIs may impose a concrete contract such
-- as "suspension is forbidden" without introducing a general policy framework.

local Execution = {}

local function current_fiber(runtime, level)
  local fiber = runtime and runtime._current_fiber
  if not fiber then
    error('execution contract requires a currently resumed fiber', level or 3)
  end
  return fiber
end

function Execution.enter(runtime, spec)
  spec = spec or {}
  if type(spec) ~= 'table' then
    error('execution contract must be a table', 2)
  end
  local fiber = current_fiber(runtime, 3)
  local stack = fiber._execution_contracts
  if not stack then
    stack = {}
    fiber._execution_contracts = stack
  end
  local contract = {
    suspension = spec.suspension,
    kind = spec.kind,
    source = spec.source,
    label = spec.label,
  }
  stack[#stack + 1] = contract
  return { fiber = fiber, depth = #stack, contract = contract }
end

function Execution.leave(runtime, token)
  local fiber = current_fiber(runtime, 3)
  local stack = fiber._execution_contracts or {}
  if type(token) ~= 'table'
    or token.fiber ~= fiber
    or token.depth ~= #stack
    or token.contract ~= stack[#stack]
  then
    error('execution contract token mismatch', 2)
  end
  stack[#stack] = nil
  return true
end

function Execution.suspension_contract(fiber)
  local stack = fiber and fiber._execution_contracts
  for i = #(stack or {}), 1, -1 do
    local contract = stack[i]
    if contract.suspension == 'forbidden' then
      return contract
    end
  end
  return nil
end

function Execution.suspension_forbidden(fiber)
  return Execution.suspension_contract(fiber) ~= nil
end

function Execution.capture_source(level)
  local debug_lib = debug
  if type(debug_lib) ~= 'table' or type(debug_lib.getinfo) ~= 'function' then
    return nil
  end
  local info = debug_lib.getinfo((level or 1) + 1, 'Sl')
  if not info then return nil end
  return {
    source = info.short_src or info.source,
    line = info.currentline,
  }
end

return Execution

-- Closure: how a Lifetime resolves and propagates consequences.
--
-- Closure has two orthogonal parts which form one contract:
--
--   * local closure: request, finish and optional force operations;
--   * propagation: pure decisions for body, cancellation and child outcomes.
--
-- The Runtime applies the contract. All externally visible changes remain Ops.

local Engine = require('fibers.internal.lifetime.closure')

local Closure = {}

local propagation_fields = {
  'on_child_outcome',
  'on_cancel_requested',
  'on_body_result',
  'allow_unstructured',
  'allow_admit',
  'allow_move',
  'permit_unstructured',
  'permit_admission',
  'permit_outward_move',
  'child_failure',
}

local propagation_callbacks = {
  on_child_outcome = true,
  on_cancel_requested = true,
  on_body_result = true,
}

local propagation_booleans = {
  allow_unstructured = true,
  allow_admit = true,
  allow_move = true,
  permit_unstructured = true,
  permit_admission = true,
  permit_outward_move = true,
}

local function copy_propagation(target, source, label)
  if source == nil then return target end
  if type(source) ~= 'table' then
    error((label or 'Closure propagation') .. ' must be a table', 3)
  end
  for i = 1, #propagation_fields do
    local field = propagation_fields[i]
    local value = source[field]
    if value ~= nil then
      if propagation_callbacks[field] and type(value) ~= 'function' then
        error((label or 'Closure propagation') .. ' ' .. field .. ' must be a function', 3)
      end
      if propagation_booleans[field] and type(value) ~= 'boolean' then
        error((label or 'Closure propagation') .. ' ' .. field .. ' must be a boolean', 3)
      end
      target[field] = value
    end
  end
  return target
end

-- Return a propagation-only snapshot. Child Lifetimes inherit this projection,
-- never their parent's local request/finish/force operations.
function Closure.propagation(contract)
  return copy_propagation({}, contract, 'Closure propagation')
end

-- Local closure constructors and failure/recovery operations are implemented by
-- the private engine but form part of this one public concept.
for _, name in ipairs({
  'protocol',
  'none',
  'request_then_wait',
  'require_ok',
  'close_op',
  'Failure',
  'is_failure',
}) do
  Closure[name] = Engine[name]
end

-- A running closure waits for the body during normal completion and requests
-- cancellation during abnormal closure. Propagation decisions may be supplied
-- in the same table.
function Closure.running(opts)
  return copy_propagation(Engine.running(), opts, 'Closure.running options')
end

-- Compose domain-local shutdown with boundary propagation without mutating
-- either input. The local request/finish/force operations remain authoritative;
-- the second argument contributes only pure propagation and admission rules.
function Closure.combine(local_contract, propagation)
  local local_closure = Engine.protocol(local_contract, 'local closure')
  return copy_propagation(local_closure, propagation, 'Closure.combine propagation')
end

local Boundary = {}

function Boundary:on_cancel_requested(_parent, _state, reason)
  return { seal = true, cancel_children = true, reason = reason }
end

function Boundary:on_body_result(_parent, _state, ok, primary)
  return ok
    and { seal = true, cancel_children = false }
    or { seal = true, cancel_children = true, reason = primary }
end

local function boundary(kind, opts, default_name)
  if opts ~= nil and type(opts) ~= 'table' then
    error('Closure.' .. kind .. ' options must be a table', 3)
  end
  opts = opts or {}
  if opts.name ~= nil and type(opts.name) ~= 'string' then
    error('Closure.' .. kind .. ' name must be a string', 3)
  end
  local contract = Closure.running()
  contract.name = opts.name or default_name
  contract.permit_unstructured = opts.allow_unstructured == true
  contract.permit_outward_move = opts.allow_outward_move ~= false
  contract.permit_admission = opts.allow_admission ~= false
  return contract, opts
end

local Nursery = setmetatable({}, { __index = Boundary })
Nursery.__index = Nursery

function Closure.nursery(opts)
  local contract = boundary('nursery', opts, 'nursery')
  return setmetatable(contract, Nursery)
end

function Nursery:on_child_outcome(_parent, _state, _child, exit)
  if type(exit) == 'table' and exit.tag == 'failed' then
    return { fail_boundary = true, seal = true, cancel_body = true, cancel_children = true }
  end
  return {}
end

local Supervisor = setmetatable({}, { __index = Boundary })
Supervisor.__index = Supervisor

function Closure.supervisor(opts)
  local contract, options = boundary('supervisor', opts, 'supervisor')
  local mode = options.child_failure or 'fail_at_exit'
  if mode ~= 'fail_at_exit' and mode ~= 'collect' and mode ~= 'ignore' then
    error('supervisor child_failure must be fail_at_exit, collect, or ignore', 2)
  end
  contract.child_failure = mode
  return setmetatable(contract, Supervisor)
end

function Supervisor:on_child_outcome(_parent, state, _child, exit)
  if type(exit) == 'table' and exit.tag == 'failed' and self.child_failure == 'fail_at_exit'
      and not state.first_child_failure then
    state.first_child_failure = state.child_failures[#state.child_failures]
  end
  return {}
end

return Closure

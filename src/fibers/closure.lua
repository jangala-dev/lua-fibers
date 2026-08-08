-- Closure: how a Lifetime resolves and propagates consequences.
--
-- Closure has two orthogonal parts which form one contract:
--
--   * local closure: request, finish and optional force operations;
--   * propagation: pure decisions for body, cancellation and child outcomes.
--
-- The Runtime applies the contract. All externally visible changes remain Ops.

local Engine = require('fibers.internal.lifetime.closure')
local Contract = require('fibers.internal.contract')

local Closure = {}

local propagation_fields = {
  'on_child_outcome',
  'on_cancel_requested',
  'on_body_result',
  'permit_admission',
  'permit_outward_move',
  'child_failure',
}

local propagation_callbacks = {
  on_child_outcome = true,
  on_cancel_requested = true,
  on_body_result = true,
}

local propagation_allowed = {}
for i = 1, #propagation_fields do propagation_allowed[propagation_fields[i]] = true end

local propagation_booleans = {
  permit_admission = true,
  permit_outward_move = true,
}

local function copy_propagation(target, source, label, strict)
  if source == nil then return target end
  if type(source) ~= 'table' then
    error((label or 'Closure propagation') .. ' must be a table', 3)
  end
  if strict then
    Contract.options(source, propagation_allowed, label or 'Closure propagation', 3)
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
  if opts == nil then return Engine.running() end
  local allowed = { name = true }
  for key in pairs(propagation_allowed) do allowed[key] = true end
  opts = Contract.options(opts, allowed, 'Closure.running options', 2)
  if opts.name ~= nil then Contract.non_empty_string(opts.name, 'Closure.running name', 2) end
  local contract = copy_propagation(Engine.running(), opts, 'Closure.running options', false)
  if opts.name ~= nil then contract.name = opts.name end
  return contract
end

-- Compose domain-local shutdown with boundary propagation without mutating
-- either input. The local request/finish/force operations remain authoritative;
-- the second argument contributes only pure propagation and admission rules.
function Closure.combine(local_contract, propagation)
  local local_closure = Engine.protocol(local_contract, 'local closure')
  return copy_propagation(local_closure, propagation, 'Closure.combine propagation', true)
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
  local allowed = { name = true, permit_outward_move = true, permit_admission = true }
  if kind == 'supervisor' then allowed.child_failure = true end
  opts = Contract.options(opts, allowed, 'Closure.' .. kind .. ' options', 3)
  if opts.name ~= nil then Contract.non_empty_string(opts.name, 'Closure.' .. kind .. ' name', 3) end
  Contract.optional_boolean(opts.permit_outward_move, 'Closure.' .. kind .. ' permit_outward_move', 3)
  Contract.optional_boolean(opts.permit_admission, 'Closure.' .. kind .. ' permit_admission', 3)
  local contract = Closure.running()
  contract.name = opts.name or default_name
  contract.permit_outward_move = opts.permit_outward_move ~= false
  contract.permit_admission = opts.permit_admission ~= false
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

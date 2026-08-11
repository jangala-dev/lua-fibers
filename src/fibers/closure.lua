-- Closure: local Lifetime shutdown protocols and Scope supervision policy.
--
-- The two are deliberately separate:
--
--   * protocol: how one Lifetime discharges its own continuing consequence;
--   * policy: how a Scope reacts to body, cancellation and child outcomes.
--
-- `running`, `protocol`, `none` and `request_then_wait` construct local
-- protocols. `nursery` and `supervisor` construct Scope policies. A Lifetime
-- never stores a hybrid value containing both.

local Driver = require('fibers.internal.lifetime.closure')
local Contract = require('fibers.internal.contract')

local Closure = {}

local POLICY_FIELDS = {
  'on_child_outcome',
  'on_cancel_requested',
  'on_body_result',
  'permit_admission',
  'permit_outward_move',
  'child_failure',
}

local POLICY_CALLBACKS = {
  on_child_outcome = true,
  on_cancel_requested = true,
  on_body_result = true,
}

local POLICY_BOOLEANS = {
  permit_admission = true,
  permit_outward_move = true,
}

local POLICY_ALLOWED = { name = true }
for i = 1, #POLICY_FIELDS do POLICY_ALLOWED[POLICY_FIELDS[i]] = true end

local function copy_policy(target, source, label, strict)
  target = target or {}
  if source == nil then return target end
  if type(source) ~= 'table' then
    error((label or 'Closure policy') .. ' must be a table', 3)
  end
  if strict then Contract.options(source, POLICY_ALLOWED, label or 'Closure policy', 3) end
  for i = 1, #POLICY_FIELDS do
    local field = POLICY_FIELDS[i]
    local value = source[field]
    if value ~= nil then
      if POLICY_CALLBACKS[field] and type(value) ~= 'function' then
        error((label or 'Closure policy') .. ' ' .. field .. ' must be a function', 3)
      end
      if POLICY_BOOLEANS[field] and type(value) ~= 'boolean' then
        error((label or 'Closure policy') .. ' ' .. field .. ' must be a boolean', 3)
      end
      target[field] = value
    end
  end
  return target
end

function Closure.policy(value)
  return copy_policy({}, value, 'Closure policy', true)
end

-- Internal policy inheritance helper. Local shutdown is never inherited.
function Closure._merge_policy(base, override)
  local out = copy_policy({}, base, 'base Closure policy')
  return copy_policy(out, override, 'Closure policy override')
end

-- Local protocol constructors and structural closure processes are implemented
-- by the private driver. `start_retire_op` remains transactional; completion is
-- observed later through the returned CloseProcess.
for _, name in ipairs({
  'protocol',
  'none',
  'request_then_wait',
  'require_ok',
  'start_retire_op',
  'Process',
  'is_process',
  'Failure',
  'is_failure',
}) do
  Closure[name] = Driver[name]
end

-- A running local consequence is interrupted on abnormal closure and waited
-- for during finish. Supervision policy belongs to Scope, not this protocol.
function Closure.running(...)
  if select('#', ...) ~= 0 then
    error('Closure.running takes no policy; pass policy to Scope/spawn instead', 2)
  end
  return Driver.running()
end

local PolicyBase = {}
PolicyBase.__index = PolicyBase

function PolicyBase:on_cancel_requested(_parent, _state, reason)
  return { seal = true, cancel_children = true, reason = reason }
end

function PolicyBase:on_body_result(_parent, _state, ok, primary)
  return ok
    and { seal = true, cancel_children = false }
    or { seal = true, cancel_children = true, reason = primary }
end

local function policy_base(kind, opts)
  local allowed = { name = true, permit_outward_move = true, permit_admission = true }
  if kind == 'supervisor' then allowed.child_failure = true end
  opts = Contract.options(opts, allowed, 'Closure.' .. kind .. ' options', 3)
  if opts.name ~= nil then Contract.non_empty_string(opts.name, 'Closure.' .. kind .. ' name', 3) end
  Contract.optional_boolean(opts.permit_outward_move, 'Closure.' .. kind .. ' permit_outward_move', 3)
  Contract.optional_boolean(opts.permit_admission, 'Closure.' .. kind .. ' permit_admission', 3)
  return setmetatable({
    permit_outward_move = opts.permit_outward_move ~= false,
    permit_admission = opts.permit_admission ~= false,
  }, PolicyBase), opts
end

local Nursery = setmetatable({}, { __index = PolicyBase })
Nursery.__index = Nursery

function Closure.nursery(opts)
  local policy = policy_base('nursery', opts)
  return setmetatable(policy, Nursery)
end

function Nursery:on_child_outcome(_parent, _state, _child, exit)
  if type(exit) == 'table' and exit.tag == 'failed' then
    return { fail_boundary = true, seal = true, cancel_body = true, cancel_children = true }
  end
  return {}
end

local Supervisor = setmetatable({}, { __index = PolicyBase })
Supervisor.__index = Supervisor

function Closure.supervisor(opts)
  local policy, options = policy_base('supervisor', opts)
  local mode = options.child_failure or 'fail_at_exit'
  if mode ~= 'fail_at_exit' and mode ~= 'collect' and mode ~= 'ignore' then
    error('supervisor child_failure must be fail_at_exit, collect, or ignore', 2)
  end
  policy.child_failure = mode
  return setmetatable(policy, Supervisor)
end

function Supervisor:on_child_outcome(_parent, _state, _child, exit)
  if type(exit) == 'table' and exit.tag == 'failed' and self.child_failure == 'fail_at_exit' then
    return { fail_boundary = true }
  end
  return {}
end

return Closure

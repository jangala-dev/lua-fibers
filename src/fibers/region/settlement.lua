-- Structural settlement protocols for owned records.
--
-- Admission installs ownership records containing normalised settlement
-- protocols. A Region owns generic claim/resolve state; this module provides
-- standard strategies that claim a subtree, perform settlement protocols, and
-- then resolve the claim. Settlement is inline policy work; detached settlement
-- drivers are not part of the core lifetime calculus.

local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local Protected = require('fibers.internal.protected')

local Settlement = {}

local SettlementFailure = {}
SettlementFailure.__index = SettlementFailure

local function settlement_failure_message(item, err, mark_error)
  local name = type(item) == 'table' and (item.name or item._fibers_id) or item
  local message = 'settlement failed'
  if name ~= nil then
    message = message .. ' for ' .. tostring(name)
  end
  message = message .. ': ' .. tostring(err)
  if mark_error ~= nil then
    message = message .. ' (failed to record settlement failure: ' .. tostring(mark_error) .. ')'
  end
  return message
end

function SettlementFailure.new(claim, err, mark_error)
  return setmetatable({
    _fibers_settlement_failure = true,
    _fibers_value = true,
    kind = 'settlement_failure',
    item = claim.root,
    region = claim.region,
    claim = claim,
    claim_id = claim.id,
    purpose = claim.purpose,
    reason = claim.reason,
    records = claim.records,
    error = err,
    mark_error = mark_error,
    message = settlement_failure_message(claim.root, err, mark_error),
  }, SettlementFailure)
end

function SettlementFailure.is(x)
  return type(x) == 'table' and x._fibers_settlement_failure == true
end

function SettlementFailure:resolve_op(resolution)
  return self.region:resolve_op(self.claim, resolution)
end

function SettlementFailure:discharge_op()
  return self.region:discharge_claim_op(self.claim)
end

function SettlementFailure:restore_op()
  return self.region:restore_claim_op(self.claim)
end

function SettlementFailure:tostring()
  return self.message
end

SettlementFailure.__tostring = SettlementFailure.tostring
Settlement.Failure = SettlementFailure
Settlement.is_failure = SettlementFailure.is

local function true_op()
  return Op.always(true)
end

local function perform_masked(op)
  local rt = Runtime.current()
  if not rt then
    error('settlement requires a current runtime', 2)
  end
  return rt:_perform_current(op, nil, true)
end

local function require_context(ctx)
  if type(ctx) ~= 'table' or type(ctx.claim_op) ~= 'function' or type(ctx.resolve_op) ~= 'function' then
    error('settlement requires a context with claim_op and resolve_op', 3)
  end
  return ctx
end

local function ensure_op(op, label)
  if op == nil then
    return true_op()
  end
  if type(op) ~= 'table' or type(op.and_then) ~= 'function' then
    error((label or 'settlement step') .. ' must return an Op', 3)
  end
  return op
end

function Settlement.normalize(settle, label)
  if settle == nil then
    return {
      _fibers_settlement_protocol = true,
      name = 'none',
      discharge_op = function()
        return true_op()
      end,
    }
  end
  if type(settle) == 'function' then
    return {
      _fibers_settlement_protocol = true,
      name = label or 'function',
      discharge_op = settle,
    }
  end
  if type(settle) == 'table' then
    if settle._fibers_settlement_protocol then
      return settle
    end
    local discharge = settle.discharge_op
    if type(discharge) ~= 'function' then
      error((label or 'settlement protocol') .. ' requires a discharge_op function', 3)
    end
    if settle.request_op ~= nil and type(settle.request_op) ~= 'function' then
      error((label or 'settlement protocol') .. ' request_op must be a function', 3)
    end
    if settle.force_op ~= nil and type(settle.force_op) ~= 'function' then
      error((label or 'settlement protocol') .. ' force_op must be a function', 3)
    end
    return {
      _fibers_settlement_protocol = true,
      name = settle.name or label or 'protocol',
      request_op = settle.request_op,
      discharge_op = discharge,
      force_op = settle.force_op,
      raw = settle,
    }
  end
  error((label or 'settlement protocol') .. ' must be a function or protocol table', 3)
end

function Settlement.name_of(settle, fallback)
  if type(settle) == 'table' then
    return settle.name or fallback
  end
  return fallback
end

function Settlement.protocol(settle, label)
  local protocol = Settlement.normalize(settle, label)
  return function(ctx, record, claim)
    local op
    if protocol.request_op then
      op = ensure_op(protocol.request_op(ctx, record, claim), protocol.name .. '.request_op')
      return op:and_then(function()
        return ensure_op(protocol.discharge_op(ctx, record, claim), protocol.name .. '.discharge_op')
      end)
    end
    return ensure_op(protocol.discharge_op(ctx, record, claim), protocol.name .. '.discharge_op')
  end
end

function Settlement.none()
  return Settlement.protocol({
    name = 'none',
    discharge_op = function()
      return true_op()
    end,
  })
end

function Settlement.request_then_wait(request_op, settled_op)
  if type(request_op) ~= 'function' then
    error('request_then_wait expects request_op function', 2)
  end
  if type(settled_op) ~= 'function' then
    error('request_then_wait expects settled_op function', 2)
  end
  return Settlement.protocol(function(ctx, record, claim)
    local reason = claim and claim.reason or nil
    return request_op(ctx, record, reason, claim):wrap(function(...)
      perform_masked(settled_op(ctx, record, reason, claim))
      return ...
    end)
  end, 'request_then_wait')
end

function Settlement.task_interrupt()
  return Settlement.request_then_wait(function(_ctx, record, reason)
    return record.item:request_cancel_op(reason)
  end, function(_ctx, record)
    return record.item:exit_op():map(function()
      return true
    end)
  end)
end

function Settlement.task_join_only()
  return Settlement.protocol({
    name = 'task_join_only',
    discharge_op = function(_ctx, record)
      return record.item:exit_op():map(function()
        return true
      end)
    end,
  })
end

function Settlement.flow()
  return Settlement.request_then_wait(function(_ctx, record, reason)
    return record.item:abort_op(reason):map(function()
      return true
    end)
  end, function(_ctx, record)
    return record.item:closed_op():and_then(function(ok, err)
      if not ok then
        error(err or 'flow settlement failed', 0)
      end
      return Op.always(true)
    end)
  end)
end

function Settlement.stream()
  return Settlement.request_then_wait(function(_ctx, record, reason)
    return Op.tensor({
      record.item:shutdown_read_op(reason),
      record.item:abort_write_op(reason),
    }):map(function()
      return true
    end)
  end, function(_ctx, record)
    return record.item:closed_op():and_then(function(ok, err)
      if not ok then
        error(err or 'stream settlement failed', 0)
      end
      return Op.always(true)
    end)
  end)
end

local function protocol_for(record)
  return Settlement.protocol(record.settle, record.settle_name)
end

local function perform_protocols(ctx, claim)
  for i = 1, #claim.records do
    local record = claim.records[i]
    perform_masked(protocol_for(record)(ctx, record, claim))
  end
end

local function with_settlement_authority(ctx, fn)
  require_context(ctx)
  ctx._settlement_depth = (ctx._settlement_depth or 0) + 1
  local ok, a, b, c = Protected.pcall(fn)
  ctx._settlement_depth = ctx._settlement_depth - 1
  if not ok then
    error(a, 0)
  end
  return a, b, c
end

local function resolve_failed_op(ctx, claim, err)
  require_context(ctx)
  return ctx:resolve_op(claim, { kind = 'fail', error = err })
end

local function resolve_discharge_op(ctx, claim)
  require_context(ctx)
  return ctx:resolve_op(claim, { kind = 'discharge' })
end

local function mark_failed(ctx, claim, err)
  return Protected.pcall(function()
    perform_masked(resolve_failed_op(ctx, claim, err))
  end)
end

local function run_claim_inline(ctx, claim, after_settle)
  local ok, err = Protected.pcall(function()
    with_settlement_authority(ctx, function()
      perform_protocols(ctx, claim)
    end)
    perform_masked(resolve_discharge_op(ctx, claim))
  end)
  if not ok then
    local marked, mark_error = mark_failed(ctx, claim, err)
    local failure = SettlementFailure.new(claim, err, marked and nil or mark_error)
    error(failure, 0)
  end
  if after_settle then
    perform_masked(after_settle(ctx, claim))
  end
  return claim.root
end

function Settlement.claim_item_op(ctx, item, purpose, after_settle)
  require_context(ctx)
  return ctx:claim_op(item, purpose):wrap(function(claim)
    return run_claim_inline(ctx, claim, after_settle)
  end)
end

function Settlement.retire_item_op(ctx, item, reason, after_settle)
  return Settlement.claim_item_op(ctx, item, { type = 'retire', reason = reason }, after_settle)
end

return Settlement

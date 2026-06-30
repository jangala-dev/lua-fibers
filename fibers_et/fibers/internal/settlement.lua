-- Structural settlement protocols for owned records.
--
-- Admission installs ownership records containing normalised settlement
-- protocols. A Region owns generic claim/resolve state; this module provides
-- standard strategies that claim a subtree, perform settlement protocols, and
-- then resolve the claim. Inline settlement is the default for scope exit; a
-- detached driver strategy remains available for callers that explicitly need it.

local Op = require('fibers.atoms.op')
local Runtime = require('fibers.kernel.runtime')
local Protected = require('fibers.kernel.protected')

local Settlement = {}

local function true_op() return Op.always(true) end

local function perform_masked(op)
  local rt = Runtime.current()
  if not rt then error('settlement requires a current runtime', 2) end
  return rt:perform(op, { masked = true })
end

function Settlement.perform_masked(op) return perform_masked(op) end

local function require_context(ctx)
  if type(ctx) ~= 'table' or type(ctx.claim_op) ~= 'function' or type(ctx.resolve_op) ~= 'function' then
    error('settlement requires a context with claim_op and resolve_op', 3)
  end
  return ctx
end

local function ensure_op(op, label)
  if op == nil then return true_op() end
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
      discharge_op = function() return true_op() end,
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
    if settle._fibers_settlement_protocol then return settle end
    local discharge = settle.discharge_op or settle.discharge or settle.settle_op or settle.settle
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
  if type(settle) == 'table' then return settle.name or fallback end
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
    discharge_op = function() return true_op() end,
  })
end

function Settlement.request_then_wait(request_op, settled_op)
  if type(request_op) ~= 'function' then error('request_then_wait expects request_op function', 2) end
  if type(settled_op) ~= 'function' then error('request_then_wait expects settled_op function', 2) end
  return Settlement.protocol(function(ctx, record, claim)
    local reason = claim and claim.reason or nil
    return request_op(ctx, record, reason, claim):wrap(function(...)
      perform_masked(settled_op(ctx, record, reason, claim))
      return ...
    end)
  end, 'request_then_wait')
end

function Settlement.task_interrupt()
  return Settlement.request_then_wait(
    function(_ctx, record, reason) return record.item:request_cancel_op(reason) end,
    function(_ctx, record) return record.item:exit_op():map(function() return true end) end
  )
end

function Settlement.task_join_only()
  return Settlement.protocol({
    name = 'task_join_only',
    discharge_op = function(_ctx, record)
      return record.item:exit_op():map(function() return true end)
    end,
  })
end

function Settlement.flow()
  return Settlement.request_then_wait(
    function(_ctx, record, reason) return record.item:shutdown_op(reason):map(function() return true end) end,
    function(_ctx, record) return record.item:closed_op():map(function() return true end) end
  )
end

function Settlement.stream()
  return Settlement.protocol({
    name = 'stream',
    discharge_op = function(_ctx, record, claim)
      return record.item:shutdown_op(claim and claim.reason):map(function() return true end)
    end,
  })
end

local function driver_name_for(claim)
  local item = claim and claim.root
  local name = item and (item.name or item._fibers_id) or 'item'
  local typ = type(claim and claim.purpose) == 'table' and claim.purpose.type or 'claim'
  return 'settle:' .. tostring(typ) .. ':' .. tostring(name)
end

local function protocol_for(record)
  return Settlement.protocol(record and record.settle, record and record.settle_name or nil)
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
  if not ok then error(a, 0) end
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
  Protected.pcall(function()
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
    -- The claim has already committed. Settlement failure therefore becomes
    -- committed, observable ownership state rather than an implicit rollback or
    -- a silent cleanup error.
    mark_failed(ctx, claim, err)
    error(err, 0)
  end
  if after_settle then perform_masked(after_settle(ctx, claim)) end
  return claim.root
end

local function make_driver(ctx, claim, after_settle)
  local Task = require('fibers.task')
  local driver = Task.new(function()
    return run_claim_inline(ctx, claim, after_settle)
  end, driver_name_for(claim))
  driver._fibers_settlement_driver = true
  driver.claim = claim
  driver.settled_item = claim.root
  driver.settled_records = claim.records
  return driver
end

function Settlement.claim_item_detached_op(ctx, item, purpose, after_settle)
  require_context(ctx)
  return ctx:claim_op(item, purpose):and_then(function(claim)
    local driver = make_driver(ctx, claim, after_settle)
    return Op.emit(driver:_spawn_effect()):wrap(function()
      perform_masked(driver:await_op())
      return claim.root
    end)
  end)
end

function Settlement.claim_item_inline_op(ctx, item, purpose, after_settle)
  require_context(ctx)
  return ctx:claim_op(item, purpose):wrap(function(claim)
    return run_claim_inline(ctx, claim, after_settle)
  end)
end

function Settlement.claim_item_op(ctx, item, purpose, after_settle, opts)
  opts = opts or {}
  if opts.mode == 'detached' then return Settlement.claim_item_detached_op(ctx, item, purpose, after_settle) end
  return Settlement.claim_item_inline_op(ctx, item, purpose, after_settle)
end

function Settlement.retire_item_op(ctx, item, reason, after_settle, opts)
  return Settlement.claim_item_op(ctx, item, { type = 'retire', reason = reason }, after_settle, opts)
end

return Settlement

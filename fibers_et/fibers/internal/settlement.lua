-- Structural settlement driver for owned records.
--
-- Admission installs ownership records containing Op-valued settlement
-- protocols.  A Region owns generic claim/settle state; this module provides a
-- standard driver that claims a subtree, performs settlement protocols, and then
-- settles the claim.

local Op = require('fibers.base.op')
local Runtime = require('fibers.kernel.runtime')
local Protected = require('fibers.kernel.protected')

local Settlement = {}

local function true_op() return Op.always(true) end

local function perform_masked(op)
  local rt = Runtime.current()
  if not rt then error('settlement driver requires a current runtime', 2) end
  return rt:perform(op, { masked = true })
end

function Settlement.perform_masked(op) return perform_masked(op) end

function Settlement.none()
  return function() return true_op() end
end

function Settlement.protocol(fn)
  if fn == nil then return Settlement.none() end
  if type(fn) ~= 'function' then error('settlement protocol must be a function', 2) end
  return fn
end

function Settlement.request_then_wait(request_op, settled_op)
  if type(request_op) ~= 'function' then error('request_then_wait expects request_op function', 2) end
  if type(settled_op) ~= 'function' then error('request_then_wait expects settled_op function', 2) end
  return function(ctx, record, claim)
    local reason = claim and claim.reason or nil
    return request_op(ctx, record, reason, claim):wrap(function(...)
      perform_masked(settled_op(ctx, record, reason, claim))
      return ...
    end)
  end
end

function Settlement.task_interrupt()
  return Settlement.request_then_wait(
    function(_ctx, record, reason) return record.item:request_cancel_op(reason) end,
    function(_ctx, record) return record.item:exit_op():map(function() return true end) end
  )
end

function Settlement.task_join_only()
  return function(_ctx, record)
    return record.item:exit_op():map(function() return true end)
  end
end

function Settlement.flow()
  return Settlement.request_then_wait(
    function(_ctx, record, reason) return record.item:shutdown_op(reason):map(function() return true end) end,
    function(_ctx, record) return record.item:closed_op():map(function() return true end) end
  )
end

function Settlement.stream()
  return function(_ctx, record, claim)
    return record.item:shutdown_op(claim and claim.reason):map(function() return true end)
  end
end

local function driver_name_for(claim)
  local item = claim and claim.root
  local name = item and (item.name or item._fibers_id) or 'item'
  local typ = type(claim and claim.purpose) == 'table' and claim.purpose.type or 'claim'
  return 'settle:' .. tostring(typ) .. ':' .. tostring(name)
end

local function protocol_for(record)
  local f = record and record.settle
  if f == nil then return Settlement.none() end
  if type(f) ~= 'function' then error('owned record has non-function settlement protocol', 2) end
  return f
end

local function failure_event_op(ctx, claim, err)
  if type(ctx) == 'table' and type(ctx._event) == 'function' then
    local first = claim.records and claim.records[1]
    return Op.emit(ctx:_event('settlement_failed', {
      item = claim.root,
      task = claim.root,
      claim = claim,
      claim_id = claim.id,
      purpose = claim.purpose,
      settle = first and first.settle_name,
      error = err,
      error_message = tostring(err),
    }))
  end
  return Op.always(true)
end

local function perform_protocols(ctx, claim)
  for i = 1, #(claim.records or {}) do
    local record = claim.records[i]
    perform_masked(protocol_for(record)(ctx, record, claim))
  end
end

local function make_driver(ctx, claim, after_settle)
  local Task = require('fibers.base.task')
  local driver = Task.new(function()
    local ok, err = Protected.pcall(function()
      perform_protocols(ctx, claim)
      perform_masked(ctx.region:settle_claim_op(claim))
    end)
    if not ok then
      -- The claim has already committed.  Settlement failure therefore becomes
      -- committed, observable ownership state rather than an implicit rollback
      -- or a silent failed driver task.
      Protected.pcall(function()
        perform_masked(ctx.region:settlement_failed_op(claim, err))
        perform_masked(failure_event_op(ctx, claim, err))
      end)
      error(err, 0)
    end
    if after_settle then perform_masked(after_settle(ctx, claim)) end
    return claim.root
  end, driver_name_for(claim))
  driver._fibers_settlement_driver = true
  driver.claim = claim
  driver.settled_item = claim.root
  driver.settled_records = claim.records
  return driver
end

function Settlement.claim_item_op(ctx, item, purpose, after_settle)
  return ctx.region:claim_op(item, purpose):and_then(function(claim)
    local driver = make_driver(ctx, claim, after_settle)
    return Op.emit(driver:_spawn_effect()):wrap(function()
      perform_masked(driver:await_op())
      return claim.root
    end)
  end)
end

function Settlement.settle_item_op(ctx, item, reason, after_settle)
  return Settlement.claim_item_op(ctx, item, { type = 'settle', reason = reason }, after_settle)
end

return Settlement

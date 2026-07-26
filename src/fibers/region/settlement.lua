-- Ordered structural settlement protocols for owned records.
--
-- A claim freezes one owned subtree in pre-order. Settlement has distinct
-- phases:
--
--   1. request quiescence in pre-order (parents before children);
--   2. settle in reverse pre-order (children before parents);
--   3. discharge the complete claim atomically from the Region ledger.
--
-- Progress is retained on the claim. A failed attempt may therefore be retried
-- without repeating successful requests or pretending that settled resources
-- became live again.

local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local Protected = require('fibers.internal.protected')

local Settlement = {}
local unpack_ = table.unpack or unpack

local function pack(...)
  return { n = select('#', ...), ... }
end

local SettlementFailure = {}
SettlementFailure.__index = SettlementFailure

local function item_name(item)
  return type(item) == 'table' and (item.name or item._fibers_id) or item
end

local function settlement_failure_message(claim, failures, mark_error)
  local message = 'settlement failed'
  local name = item_name(claim.root)
  if name ~= nil then
    message = message .. ' for ' .. tostring(name)
  end
  local first = failures and failures[1]
  if first then
    message = message .. ' during ' .. tostring(first.phase) .. ' of ' .. tostring(item_name(first.item))
    message = message .. ': ' .. tostring(first.error)
    if #failures > 1 then
      message = message .. ' (and ' .. tostring(#failures - 1) .. ' further failure(s))'
    end
  end
  if mark_error ~= nil then
    message = message .. ' (failed to record settlement failure: ' .. tostring(mark_error) .. ')'
  end
  return message
end

local function public_progress(claim)
  local out = {}
  for i = 1, #(claim.progress or {}) do
    local entry = claim.progress[i]
    out[i] = {
      _fibers_value = true,
      item = entry.item,
      record = entry.record,
      request_state = entry.request_state,
      request_error = entry.request_error,
      force_state = entry.force_state,
      force_error = entry.force_error,
      settlement_state = entry.settlement_state,
      settlement_error = entry.settlement_error,
      state = entry.state,
    }
  end
  return out
end

function SettlementFailure.new(claim, failures, mark_error)
  local first = failures and failures[1]
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
    progress = public_progress(claim),
    failures = failures or {},
    error = first and first.error or 'settlement incomplete',
    mark_error = mark_error,
    message = settlement_failure_message(claim, failures, mark_error),
  }, SettlementFailure)
end

function SettlementFailure.is(x)
  return type(x) == 'table' and x._fibers_settlement_failure == true
end

function SettlementFailure:retry_op()
  return Settlement.retry_claim_op(self.claim.context or self.region, self.claim)
end

function SettlementFailure:force_op()
  return Settlement.force_claim_op(self.claim.context or self.region, self.claim)
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
  if type(ctx) ~= 'table' or type(ctx.claim_op) ~= 'function' then
    error('settlement requires a context with claim_op', 3)
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

local function validate_step(protocol, field, label)
  local step = protocol[field]
  if step ~= nil and type(step) ~= 'function' then
    error((label or 'settlement protocol') .. ' ' .. field .. ' must be a function', 3)
  end
end

function Settlement.require_ok(message)
  return function(ok, err)
    if not ok then
      error(err or message or 'settlement operation failed', 0)
    end
    return true
  end
end

function Settlement.normalize(protocol, label)
  if protocol == nil then
    return {
      _fibers_settlement_protocol = true,
      name = 'none',
      settle_op = function()
        return true_op()
      end,
    }
  end
  if type(protocol) ~= 'table' then
    error((label or 'settlement protocol') .. ' must be a protocol table', 3)
  end
  if protocol._fibers_settlement_protocol then
    validate_step(protocol, 'request_op', label)
    validate_step(protocol, 'settle_op', label)
    validate_step(protocol, 'force_op', label)
    validate_step(protocol, 'request_result', label)
    validate_step(protocol, 'settle_result', label)
    validate_step(protocol, 'force_result', label)
    if type(protocol.settle_op) ~= 'function' then
      error((label or 'settlement protocol') .. ' requires a settle_op function', 3)
    end
    return protocol
  end
  validate_step(protocol, 'request_op', label)
  validate_step(protocol, 'settle_op', label)
  validate_step(protocol, 'force_op', label)
  validate_step(protocol, 'request_result', label)
  validate_step(protocol, 'settle_result', label)
  validate_step(protocol, 'force_result', label)
  if type(protocol.settle_op) ~= 'function' then
    error((label or 'settlement protocol') .. ' requires a settle_op function', 3)
  end
  return {
    _fibers_settlement_protocol = true,
    name = protocol.name or label or 'protocol',
    request_op = protocol.request_op,
    settle_op = protocol.settle_op,
    force_op = protocol.force_op,
    request_result = protocol.request_result,
    settle_result = protocol.settle_result,
    force_result = protocol.force_result,
    raw = protocol,
  }
end

function Settlement.name_of(protocol, fallback)
  if type(protocol) == 'table' then
    return protocol.name or fallback
  end
  return fallback
end

function Settlement.protocol(protocol, label)
  return Settlement.normalize(protocol, label)
end

function Settlement.none()
  return Settlement.protocol({
    name = 'none',
    settle_op = function()
      return true_op()
    end,
  })
end

function Settlement.request_then_wait(request_op, settled_op, opts)
  if type(request_op) ~= 'function' then
    error('request_then_wait expects request_op function', 2)
  end
  if type(settled_op) ~= 'function' then
    error('request_then_wait expects settled_op function', 2)
  end
  opts = opts or {}
  return Settlement.protocol({
    name = opts.name or 'request_then_wait',
    request_op = function(ctx, record, claim)
      return ensure_op(
        request_op(ctx, record, claim and claim.reason or nil, claim),
        (opts.name or 'request_then_wait') .. '.request_op'
      )
    end,
    settle_op = function(ctx, record, claim)
      return ensure_op(
        settled_op(ctx, record, claim and claim.reason or nil, claim),
        (opts.name or 'request_then_wait') .. '.settle_op'
      )
    end,
    force_op = opts.force_op,
    request_result = opts.request_result,
    settle_result = opts.settle_result,
    force_result = opts.force_result,
  })
end

function Settlement.task_interrupt()
  return Settlement.request_then_wait(function(_ctx, record, reason)
    return record.item:request_cancel_op(reason)
  end, function(_ctx, record)
    return record.item:exit_op():map(function()
      return true
    end)
  end, { name = 'task_interrupt' })
end

function Settlement.task_join_only()
  return Settlement.protocol({
    name = 'task_join_only',
    settle_op = function(_ctx, record)
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
    return record.item:closed_op()
  end, { name = 'flow', settle_result = Settlement.require_ok('flow settlement failed') })
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
    return record.item:closed_op()
  end, { name = 'stream', settle_result = Settlement.require_ok('stream settlement failed') })
end

local function protocol_for(record)
  return Settlement.normalize(record.settle, record.settle_name)
end

local function ensure_progress(claim)
  if claim.progress then
    return claim.progress
  end
  local progress, by_item = {}, {}
  for i = 1, #claim.records do
    local record = claim.records[i]
    local entry = {
      _fibers_value = true,
      index = i,
      item = record.item,
      record = record,
      request_state = 'pending',
      force_state = 'pending',
      settlement_state = 'pending',
      state = 'not_requested',
    }
    progress[i] = entry
    by_item[record.item] = entry
  end
  claim.progress = progress
  claim.progress_by_item = by_item
  return progress
end

local function update_state(entry)
  if entry.settlement_state == 'succeeded' then
    entry.state = 'settled'
  elseif entry.settlement_state == 'failed' then
    entry.state = 'settlement_failed'
  elseif entry.settlement_state == 'blocked' then
    entry.state = 'blocked_by_descendant'
  elseif entry.force_state == 'failed' then
    entry.state = 'force_failed'
  elseif entry.request_state == 'failed' then
    entry.state = 'request_failed'
  elseif entry.force_state == 'succeeded' then
    entry.state = 'forced'
  elseif entry.request_state == 'succeeded' then
    entry.state = 'requested'
  else
    entry.state = 'not_requested'
  end
end

local function run_step(ctx, claim, entry, field, state_field, error_field, phase)
  local protocol = protocol_for(entry.record)
  local step = protocol[field]
  if step == nil then
    entry[state_field] = 'succeeded'
    entry[error_field] = nil
    update_state(entry)
    return true
  end
  local ok, err = Protected.pcall(function()
    local result =
      pack(perform_masked(ensure_op(step(ctx, entry.record, claim), protocol.name .. '.' .. field)))
    local result_field = field:gsub('_op$', '_result')
    local check_result = protocol[result_field]
    if check_result then
      check_result(unpack_(result, 1, result.n))
    end
    return unpack_(result, 1, result.n)
  end)
  if ok then
    entry[state_field] = 'succeeded'
    entry[error_field] = nil
    update_state(entry)
    return true
  end
  entry[state_field] = 'failed'
  entry[error_field] = err
  entry.last_failure_phase = phase
  update_state(entry)
  return false, err
end

local function request_pass(ctx, claim)
  local progress = ensure_progress(claim)
  for i = 1, #progress do
    local entry = progress[i]
    if entry.settlement_state ~= 'succeeded' and entry.request_state ~= 'succeeded' then
      run_step(ctx, claim, entry, 'request_op', 'request_state', 'request_error', 'request')
    end
  end
end

local function force_pass(ctx, claim)
  local progress = ensure_progress(claim)
  for i = 1, #progress do
    local entry = progress[i]
    if entry.settlement_state ~= 'succeeded' and entry.force_state ~= 'succeeded' then
      local protocol = protocol_for(entry.record)
      if protocol.force_op ~= nil then
        run_step(ctx, claim, entry, 'force_op', 'force_state', 'force_error', 'force')
      end
    end
  end
end

local function child_entries_settled(claim, entry)
  for i = 1, #(entry.record.children or {}) do
    local child = claim.progress_by_item[entry.record.children[i]]
    if not child or child.settlement_state ~= 'succeeded' then
      return false
    end
  end
  return true
end

local function settlement_pass(ctx, claim)
  local progress = ensure_progress(claim)
  for i = #progress, 1, -1 do
    local entry = progress[i]
    if entry.settlement_state ~= 'succeeded' then
      local quiesced = entry.request_state == 'succeeded' or entry.force_state == 'succeeded'
      if not quiesced then
        entry.settlement_state = 'pending'
        update_state(entry)
      elseif not child_entries_settled(claim, entry) then
        entry.settlement_state = 'blocked'
        update_state(entry)
      else
        entry.settlement_state = 'pending'
        run_step(ctx, claim, entry, 'settle_op', 'settlement_state', 'settlement_error', 'settlement')
      end
    end
  end
end

local function collect_failures(claim)
  local failures = {}
  -- Report actionable protocol failures before structural blocking diagnostics.
  for i = 1, #(claim.progress or {}) do
    local entry = claim.progress[i]
    if entry.request_state == 'failed' then
      failures[#failures + 1] = { item = entry.item, phase = 'request', error = entry.request_error }
    end
    if entry.force_state == 'failed' then
      failures[#failures + 1] = { item = entry.item, phase = 'force', error = entry.force_error }
    end
    if entry.settlement_state == 'failed' then
      failures[#failures + 1] = { item = entry.item, phase = 'settlement', error = entry.settlement_error }
    end
  end
  for i = 1, #(claim.progress or {}) do
    local entry = claim.progress[i]
    if entry.settlement_state == 'blocked' then
      failures[#failures + 1] = {
        item = entry.item,
        phase = 'settlement',
        error = 'blocked by unresolved descendant',
        blocked = true,
      }
    end
  end
  return failures
end

local function claim_complete(claim)
  for i = 1, #(claim.progress or {}) do
    if claim.progress[i].settlement_state ~= 'succeeded' then
      return false
    end
  end
  return true
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

local function resolve_failed_op(ctx, claim, failures)
  require_context(ctx)
  return claim.region:_record_failed_claim_op(claim, failures, claim.progress)
end

local function resolve_settle_op(ctx, claim)
  require_context(ctx)
  return claim.region:_discharge_settled_claim_op(claim)
end

local function mark_failed(ctx, claim, failures)
  return Protected.pcall(function()
    perform_masked(resolve_failed_op(ctx, claim, failures))
  end)
end

local function run_claim_inline(ctx, claim, opts, after_settle)
  opts = opts or {}
  if claim.complete then
    error('settlement claim has already completed', 2)
  end
  if claim.running then
    error('settlement claim is already being recovered', 2)
  end

  local was_started = claim.started == true
  claim.context = claim.context or ctx
  claim.running = true

  local outer_ok, result = Protected.pcall(function()
    if was_started then
      -- A failed claim remains exclusive, but its public ledger phase is
      -- `failed`. Resume it to `claimed` before running recovery protocols so
      -- ordinary settlement authority checks remain valid.
      perform_masked(claim.region:_resume_failed_claim_op(claim))
    end

    claim.started = true
    ensure_progress(claim)

    local ok, unexpected = Protected.pcall(function()
      with_settlement_authority(ctx, function()
        if opts.force then
          force_pass(ctx, claim)
        else
          request_pass(ctx, claim)
        end
        settlement_pass(ctx, claim)
      end)
    end)

    local failures = collect_failures(claim)
    if not ok then
      failures[#failures + 1] = { item = claim.root, phase = 'driver', error = unexpected }
    end

    if not ok or not claim_complete(claim) then
      claim.complete = false
      local marked, mark_error = mark_failed(ctx, claim, failures)
      local failure = SettlementFailure.new(claim, failures, marked and nil or mark_error)
      error(failure, 0)
    end

    claim.complete = true
    perform_masked(resolve_settle_op(ctx, claim))
    if after_settle then
      perform_masked(after_settle(ctx, claim))
    end
    return claim.root
  end)

  claim.running = false
  if not outer_ok then
    error(result, 0)
  end
  return result
end

function Settlement.claim_item_op(ctx, item, purpose, after_settle)
  require_context(ctx)
  return ctx:claim_op(item, purpose):wrap(function(claim)
    return run_claim_inline(ctx, claim, nil, after_settle)
  end)
end

function Settlement.retry_claim_op(ctx, claim, after_settle)
  require_context(ctx)
  if type(claim) ~= 'table' or claim._fibers_claim ~= true then
    error('retry_claim_op expects a settlement claim', 2)
  end
  if not claim.started or claim.complete then
    error('retry_claim_op expects an incomplete started settlement claim', 2)
  end
  return Op.always(claim):wrap(function()
    return run_claim_inline(ctx, claim, nil, after_settle)
  end)
end

function Settlement.force_claim_op(ctx, claim, after_settle)
  require_context(ctx)
  if type(claim) ~= 'table' or claim._fibers_claim ~= true then
    error('force_claim_op expects a settlement claim', 2)
  end
  if not claim.started or claim.complete then
    error('force_claim_op expects an incomplete started settlement claim', 2)
  end
  return Op.always(claim):wrap(function()
    return run_claim_inline(ctx, claim, { force = true }, after_settle)
  end)
end

function Settlement.retire_item_op(ctx, item, reason, after_settle)
  return Settlement.claim_item_op(ctx, item, { type = 'retire', reason = reason }, after_settle)
end

return Settlement

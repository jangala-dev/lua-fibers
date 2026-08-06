-- Internal ordered Closure engine for Lifetime subtrees.
--
-- A close token freezes one subtree under custody in pre-order. Closure has distinct
-- phases:
--
--   1. request quiescence in pre-order (parents before children);
--   2. finish in reverse pre-order (children before parents);
--   3. retire the complete subtree atomically from the Lifetime forest.
--
-- Progress is retained on the token. A failed attempt may therefore be retried
-- without repeating successful requests or pretending that closed resources
-- became live again.

local Op = require('fibers.op')
local Lifetime = require('fibers.lifetime')
local Runtime = require('fibers.runtime')
local StateMachine = require('fibers.resource.machine')
local Effect = require('fibers.effect')
local Protected = require('fibers.protected')
local Direct = require('fibers.internal.direct')
local Label = require('fibers.internal.label')

local Closure = {}
local unpack_ = table.unpack or unpack

local function pack(...)
  return { n = select('#', ...), ... }
end

local ClosureFailure = {}
ClosureFailure.__index = ClosureFailure

-- Keep recovery authority with the failure object itself behind a local key.
-- A global weak-key table leaks on Lua 5.1 if the token can reach the failure
-- through the Lifetime outcome/report graph, because Lua 5.1 lacks ephemerons.
local RECOVERY_STATE = {}
local RECOVERY_AVAILABLE = 'available'
local RECOVERY_CONSUMED = 'consumed'
local STALE_RECOVERY = {}

local ClaimRecovery = StateMachine.isolated_select_when('closure.claim_recovery', function(state)
  return state == RECOVERY_AVAILABLE
end, function(state)
  if state ~= RECOVERY_AVAILABLE then return StateMachine.Wait end
  return StateMachine.Ready.write(RECOVERY_CONSUMED, true)
end)

-- Effect identity makes recovery authority linear across interacting product
-- lanes as well as across time. The cell records persistent consumption; the
-- same-key committed effect rejects any candidate world containing two uses.
local RecoveryClaimKind
RecoveryClaimKind = Effect.kind({
  name = 'closure.recovery_claim',
  key = function(payload) return payload.authority end,
  merge = function()
    return nil, { kind = 'effect_conflict', message = 'duplicate closure recovery authority' }
  end,
  prepare = function(_runtime, payload)
    return {
      kind = RecoveryClaimKind,
      key = payload.authority,
      payload = payload,
      discharge = function() return true end,
    }
  end,
})

local function recovery_state(failure)
  local accessor = type(failure) == 'table' and rawget(failure, RECOVERY_STATE) or nil
  return type(accessor) == 'function' and accessor() or nil
end

local function item_label(item)
  return type(item) == 'table' and Label.describe(item, item._fibers_id) or item
end

local function closure_failure_message(token, failures, mark_error)
  local message = 'closure failed'
  local name = item_label(token.root)
  if name ~= nil then
    message = message .. ' for ' .. tostring(name)
  end
  local first = failures and failures[1]
  if first then
    message = message .. ' during ' .. tostring(first.phase) .. ' of ' .. tostring(item_label(first.item))
    message = message .. ': ' .. tostring(first.error)
    if #failures > 1 then
      message = message .. ' (and ' .. tostring(#failures - 1) .. ' further failure(s))'
    end
  end
  if mark_error ~= nil then
    message = message .. ' (failed to record closure failure: ' .. tostring(mark_error) .. ')'
  end
  return message
end

local PROGRESS_FIELDS = {
  'item', 'request_state', 'request_error', 'force_state', 'force_error',
  'close_state', 'closure_error', 'state',
}

local function copy_progress(entries, public)
  local out = {}
  for i = 1, #(entries or {}) do
    local source, copy = entries[i], public and { _fibers_value = true } or {}
    for j = 1, #PROGRESS_FIELDS do
      local field = PROGRESS_FIELDS[j]
      copy[field] = source[field]
    end
    out[i] = copy
  end
  return out
end

function ClosureFailure.new(token, failures, mark_error)
  local first = failures and failures[1]
  local failure = setmetatable({
    _fibers_closure_failure = true,
    _fibers_value = true,
    kind = 'closure_failure',
    item = token.root,
    custodian = token.boundary,
    purpose = token.purpose,
    reason = token.reason,
    progress = copy_progress(token.progress, true),
    failures = failures or {},
    error = first and first.error or 'closure incomplete',
    mark_error = mark_error,
    message = closure_failure_message(token, failures, mark_error),
  }, ClosureFailure)
  local recovery = {
    token = token,
    authority = StateMachine.new(RECOVERY_AVAILABLE):label(token.id .. '-recovery'),
  }
  rawset(failure, RECOVERY_STATE, function()
    return recovery
  end)
  return failure
end

function ClosureFailure.is(x)
  return type(x) == 'table' and x._fibers_closure_failure == true
end

local function recovery_claim_op(failure)
  local recovery = recovery_state(failure)
  local token = recovery and recovery.token or nil
  if not token or not recovery.authority or recovery.authority.value ~= RECOVERY_AVAILABLE then
    error('Closure failure no longer has recovery authority', 3)
  end
  if not token.context then error('Closure recovery context is unavailable', 3) end

  -- The positive claim and the certified-absence branch refer to the same
  -- transactional cell. Two recovery operations in one world can therefore
  -- neither both claim the authority nor combine one claim with a stale branch.
  local claim = recovery.authority
    :transition_op(ClaimRecovery)
    :or_else(Op.always(STALE_RECOVERY))
  return claim:and_then(Op.guard(function(claimed)
    local effect = Effect.of(RecoveryClaimKind, { authority = recovery.authority })
    return Op.emit(effect):map(function() return claimed end)
  end)), token
end

local function stale_recovery_op()
  return Op.always(STALE_RECOVERY):wrap(function()
    error('Closure failure no longer has recovery authority', 0)
  end)
end

local function recovery_op(failure, recover)
  local claim, token = recovery_claim_op(failure)
  return claim:and_then(Op.guard(function(claimed)
    if claimed == STALE_RECOVERY then return stale_recovery_op() end
    return recover(token.context, token)
  end))
end

function ClosureFailure:retry_op()
  return recovery_op(self, Closure._retry_token_op)
end


function ClosureFailure:force_op()
  return recovery_op(self, Closure._force_token_op)
end


function ClosureFailure:inspect()
  local failures = {}
  for i = 1, #(self.failures or {}) do
    local entry = self.failures[i]
    failures[i] = {
      item = entry.item, phase = entry.phase, error = entry.error,
      blocked = entry.blocked, blocker = entry.blocker,
    }
  end
  return {
    kind = self.kind, item = self.item, custodian = self.custodian,
    purpose = self.purpose, reason = self.reason,
    progress = copy_progress(self.progress), failures = failures,
    error = self.error, message = self.message,
  }
end

function ClosureFailure:inspect_op()
  return Op.always(self:inspect())
end

function ClosureFailure:tostring()
  return self.message
end

ClosureFailure.__tostring = ClosureFailure.tostring
Closure.Failure = ClosureFailure
Closure.is_failure = ClosureFailure.is

local function true_op()
  return Op.always(true)
end

local function perform_masked(op)
  local rt = Runtime.current()
  if not rt then
    error('closure requires a current runtime', 2)
  end
  return rt:_perform_current(op, nil, true)
end

local function require_context(ctx)
  if type(ctx) ~= 'table' or ctx._fibers_scope ~= true then
    error('closure requires a Scope', 3)
  end
  return ctx
end

local function ensure_op(op, label)
  if op == nil then
    return true_op()
  end
  if type(op) ~= 'table' or type(op.and_then) ~= 'function' then
    error((label or 'Closure step') .. ' must return an Op', 3)
  end
  return op
end

local PROTOCOL_FIELDS = {
  'request_op', 'finish_op', 'force_op',
  'request_result', 'finish_result', 'force_result',
}

local function capture_protocol(protocol, label)
  local out = { _fibers_closure_protocol = true, name = protocol.name or label or 'protocol' }
  for i = 1, #PROTOCOL_FIELDS do
    local field, value = PROTOCOL_FIELDS[i], protocol[PROTOCOL_FIELDS[i]]
    if value ~= nil and type(value) ~= 'function' then
      error((label or 'Closure protocol') .. ' ' .. field .. ' must be a function', 3)
    end
    out[field] = value
  end
  return out
end

function Closure.require_ok(message)
  return function(ok, err)
    if not ok then
      error(err or message or 'closure operation failed', 0)
    end
    return true
  end
end

function Closure.protocol(protocol, label)
  local protocol_label = label or 'Closure protocol'
  if protocol == nil then
    protocol = {
      name = 'none',
      finish_op = function()
        return true_op()
      end,
    }
  elseif type(protocol) ~= 'table' then
    error(protocol_label .. ' must be a protocol table', 3)
  end

  if protocol.name ~= nil and type(protocol.name) ~= 'string' then
    error(protocol_label .. ' name must be a string', 3)
  end
  local captured = capture_protocol(protocol, label)
  if type(captured.finish_op) ~= 'function' then
    error(protocol_label .. ' requires a finish_op function', 3)
  end
  -- Capture a fresh semantic contract even when the input was normalised.
  return captured
end


function Closure.none()
  return Closure.protocol()
end

function Closure.request_then_wait(request_op, finish_op, opts)
  if type(request_op) ~= 'function' then
    error('request_then_wait expects request_op function', 2)
  end
  if type(finish_op) ~= 'function' then
    error('request_then_wait expects finish_op function', 2)
  end
  if opts ~= nil and type(opts) ~= 'table' then
    error('request_then_wait options must be a table', 2)
  end
  opts = opts or {}
  if opts.name ~= nil and type(opts.name) ~= 'string' then
    error('request_then_wait option name must be a string', 2)
  end
  local name = opts.name or 'request_then_wait'
  local function step(fn, field)
    return function(ctx, record, close)
      return ensure_op(fn(ctx, record, close and close.reason or nil, close), name .. '.' .. field)
    end
  end
  return Closure.protocol({
    name = name,
    request_op = step(request_op, 'request_op'),
    finish_op = step(finish_op, 'finish_op'),
    force_op = opts.force_op,
    request_result = opts.request_result,
    finish_result = opts.finish_result,
    force_result = opts.force_result,
  })
end


function Closure.running()
  return Closure.request_then_wait(function(_ctx, record, reason)
    if reason == Lifetime.CloseReason.NORMAL then
      return Op.always(true)
    end
    return record.lifetime:request_cancel_op(reason)
  end, function(_ctx, record)
    return record.lifetime:outcome_op():map(function()
      return true
    end)
  end, { name = 'running_lifetime' })
end


local function protocol_for(record)
  return record.closure
end

local function ensure_progress(token)
  if token.progress then
    return token.progress
  end
  local progress, by_item = {}, {}
  for i = 1, #token.records do
    local record = token.records[i]
    local entry = {
      _fibers_value = true,
      index = i,
      item = record.item,
      node = record.node or record.lifetime,
      record = record,
      request_state = 'pending',
      force_state = 'pending',
      close_state = 'pending',
      state = 'not_requested',
    }
    progress[i] = entry
    by_item[record.node or record.lifetime] = entry
  end
  token.progress = progress
  token.progress_by_item = by_item
  return progress
end

local function update_state(entry)
  if entry.close_state == 'succeeded' then
    entry.state = 'finished'
  elseif entry.close_state == 'failed' then
    entry.state = 'closure_failed'
  elseif entry.close_state == 'blocked' then
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

local function step_context(token, phase)
  return {
    _fibers_value = true,
    root = token.root,
    reason = token.reason,
    purpose = token.purpose,
    phase = phase,
    forced = phase == 'force',
  }
end

local function run_step(ctx, token, entry, field, state_field, error_field, phase)
  local protocol = protocol_for(entry.record)
  local step = protocol[field]
  if step == nil then
    entry[state_field] = 'succeeded'
    entry[error_field] = nil
    update_state(entry)
    return true
  end
  local ok, err = Protected.pcall(function()
    local result = pack(perform_masked(ensure_op(step(ctx, entry.record, step_context(token, phase)), protocol.name .. '.' .. field)))
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

local function quiesce_pass(ctx, token, force)
  local field = force and 'force' or 'request'
  local progress = ensure_progress(token)
  for i = 1, #progress do
    local entry, state_field = progress[i], field .. '_state'
    if entry.close_state ~= 'succeeded' and entry[state_field] ~= 'succeeded' then
      perform_masked(entry.node:request_close_op(token.reason))
      if not force or protocol_for(entry.record).force_op ~= nil then
        run_step(ctx, token, entry, field .. '_op', state_field, field .. '_error', field)
      end
    end
  end
end

local function child_entries_finished(token, entry)
  for i = 1, #(entry.record.children or {}) do
    local child = token.progress_by_item[entry.record.children[i]]
    if not child or child.close_state ~= 'succeeded' then
      return false
    end
  end
  return true
end

local function finish_pass(ctx, token)
  local progress = ensure_progress(token)
  for i = #progress, 1, -1 do
    local entry = progress[i]
    if entry.close_state ~= 'succeeded' then
      local quiesced = entry.request_state == 'succeeded' or entry.force_state == 'succeeded'
      if not quiesced then
        entry.close_state = 'pending'
        update_state(entry)
      elseif not child_entries_finished(token, entry) then
        entry.close_state = 'blocked'
        update_state(entry)
      else
        entry.close_state = 'pending'
        perform_masked(entry.node:_closing_op(token.reason))
        run_step(ctx, token, entry, 'finish_op', 'close_state', 'closure_error', 'close')
      end
    end
  end
end

local FAILURE_PHASES = {
  { 'request_state', 'request', 'request_error' },
  { 'force_state', 'force', 'force_error' },
  { 'close_state', 'close', 'closure_error' },
}

local function collect_failures(token)
  local failures, progress = {}, token.progress or {}
  -- Report actionable protocol failures before structural blocking diagnostics.
  for i = 1, #progress do
    local entry = progress[i]
    for j = 1, #FAILURE_PHASES do
      local spec = FAILURE_PHASES[j]
      if entry[spec[1]] == 'failed' then
        failures[#failures + 1] = { item = entry.item, phase = spec[2], error = entry[spec[3]] }
      end
    end
  end
  for i = 1, #progress do
    local entry = progress[i]
    if entry.close_state == 'blocked' then
      failures[#failures + 1] = {
        item = entry.item, phase = 'close',
        error = 'blocked by unresolved descendant', blocked = true,
      }
    end
  end
  return failures
end

local function token_finished(token)
  for i = 1, #(token.progress or {}) do
    if token.progress[i].close_state ~= 'succeeded' then
      return false
    end
  end
  return true
end

local function with_closure_authority(ctx, fn)
  require_context(ctx)
  ctx._closure_depth = (ctx._closure_depth or 0) + 1
  local ok, a, b, c = Protected.pcall(fn)
  ctx._closure_depth = ctx._closure_depth - 1
  if not ok then
    error(a, 0)
  end
  return a, b, c
end

local function resolve_failed_op(ctx, token, failures)
  require_context(ctx)
  return ctx:_store():_resolve_close_token_op(token, 'fail', { failures = failures, progress = token.progress })
end

local function resolve_finish_op(ctx, token)
  require_context(ctx)
  return ctx:_store():_resolve_close_token_op(token, 'discharge')
end

local function containment_description(blocker)
  local message = 'closure retained ' .. tostring(blocker.count or 0) .. ' unresolved descendant(s)'
  local descendants = blocker.descendants or {}
  if #descendants > 0 then
    local shown = {}
    for i = 1, math.min(#descendants, 3) do
      local entry = descendants[i]
      shown[#shown + 1] = tostring(entry.path or item_label(entry.item))
        .. ' [' .. tostring(entry.closure_phase or entry.custody_phase or 'unknown') .. ']'
    end
    message = message .. ': ' .. table.concat(shown, ', ')
    if #descendants > #shown then
      message = message .. ' (and ' .. tostring(#descendants - #shown) .. ' more)'
    end
  end
  if (blocker.host_hold_count or 0) > 0 then
    message = message .. '; ' .. tostring(blocker.host_hold_count) .. ' host hold(s) remain'
  end
  return message
end

local function containment_failures(blockers)
  local failures = {}
  for i = 1, #(blockers or {}) do
    local blocker = blockers[i]
    failures[#failures + 1] = {
      item = blocker.item or blocker.node,
      phase = 'containment',
      error = blocker.error or containment_description(blocker),
      blocked = true,
      blocker = blocker,
    }
  end
  return failures
end

local function raise_failure(ctx, token, failures)
  token.complete = false
  local marked, mark_error = Protected.pcall(function()
    perform_masked(resolve_failed_op(ctx, token, failures))
  end)
  error(ClosureFailure.new(token, failures, marked and nil or mark_error), 0)
end

local function run_token_inline(ctx, token, opts, after_finish)
  opts = opts or {}
  if token.complete then
    error('Closure token has already completed', 2)
  end
  if token.running then
    error('Closure token is already being recovered', 2)
  end

  local was_started = token.started == true
  token.context = token.context or ctx
  token.running = true

  local outer_ok, result = Protected.pcall(function()
    if was_started then
      -- A failed close token remains exclusive. Resume it before running recovery
      -- protocols so
      -- closure authority checks remain valid.
      perform_masked(ctx:_store():_resolve_close_token_op(token, 'resume'))
    end

    token.started = true
    ensure_progress(token)

    local ok, unexpected = Protected.pcall(function()
      with_closure_authority(ctx, function()
        if opts.force then
          quiesce_pass(ctx, token, true)
        else
          quiesce_pass(ctx, token, false)
        end
        finish_pass(ctx, token)
      end)
    end)

    local failures = collect_failures(token)
    if not ok then
      failures[#failures + 1] = { item = token.root, phase = 'driver', error = unexpected }
    end

    if not ok or not token_finished(token) then
      raise_failure(ctx, token, failures)
    end

    local discharged, blockers = perform_masked(resolve_finish_op(ctx, token))
    if not discharged then
      raise_failure(ctx, token, containment_failures(blockers))
    end

    token.complete = true
    if after_finish then
      perform_masked(after_finish(ctx, token))
    end
    return token.root
  end)

  token.running = false
  if not outer_ok then
    error(result, 0)
  end
  return result
end

function Closure._close_item_op(ctx, item, purpose, after_finish)
  require_context(ctx)
  return ctx:_store():_acquire_close_token_op(ctx, item, purpose):wrap(function(token)
    return run_token_inline(ctx, token, nil, after_finish)
  end)
end

local function recover_token_op(ctx, token, force, after_finish)
  require_context(ctx)
  local action = force and 'force' or 'retry'
  if type(token) ~= 'table' or token._fibers_close_token ~= true then
    error(action .. ' closure expects a Closure token', 3)
  end
  if not token.started or token.complete then
    error(action .. ' closure expects an incomplete started Closure token', 3)
  end
  return Op.always(token):wrap(function()
    return run_token_inline(ctx, token, force and { force = true } or nil, after_finish)
  end)
end

function Closure._retry_token_op(ctx, token, after_finish)
  return recover_token_op(ctx, token, false, after_finish)
end

function Closure._force_token_op(ctx, token, after_finish)
  return recover_token_op(ctx, token, true, after_finish)
end

function Closure.close_op(ctx, item, reason, after_finish)
  return Closure._close_item_op(ctx, item, { type = 'retire', reason = reason }, after_finish)
end

Direct.install(ClosureFailure, { 'retry', 'force' })

return Closure

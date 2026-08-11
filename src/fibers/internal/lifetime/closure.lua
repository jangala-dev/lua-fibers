-- Closure protocols plus the post-commit driver for Lifetime CloseClaims.
--
-- Structural closure is deliberately split across the normal Fibers phases:
--
--   * LifetimeStore transactionally acquires a CloseClaim;
--   * Op.emit starts this driver only after the complete candidate commits;
--   * the driver performs asynchronous local protocols as ordinary Fibers work;
--   * LifetimeStore transactionally records failure/restart or discharges the claim.
--
-- There is no second transactional evaluator and no post-commit `wrap` boundary.

local Op = require('fibers.op')
local Contract = require('fibers.internal.contract')
local Lifetime = require('fibers.lifetime')
local Runtime = require('fibers.runtime')
local Effect = require('fibers.effect')
local Counter = require('fibers.resource.counter')
local Completion = require('fibers.resource.completion')
local Protected = require('fibers.protected')
local Direct = require('fibers.internal.direct')
local Label = require('fibers.internal.label')

local Closure = {}
local unpack_ = table.unpack or unpack

local function pack(...)
  return { n = select('#', ...), ... }
end

local function item_label(item)
  return type(item) == 'table' and Label.describe(item, item._fibers_id) or item
end

local function item_of(node)
  return node and (node._value or node) or nil
end

local function true_op()
  return Op.always(true)
end

local function perform_masked(op)
  local rt = Runtime.current()
  if not rt then error('closure requires a current runtime', 2) end
  return rt:_perform_current(op, nil, true)
end

local function require_context(ctx)
  if type(ctx) ~= 'table' or ctx._fibers_scope ~= true then
    error('closure requires a Scope', 3)
  end
  return ctx
end

local function ensure_op(op, label)
  if type(op) ~= 'table' or type(op.and_then) ~= 'function' then
    error((label or 'Closure step') .. ' must return an Op', 3)
  end
  return op
end

-- Local protocol ------------------------------------------------------------

local PROTOCOL_FIELDS = {
  'request_op', 'finish_op', 'force_op',
  'request_result', 'finish_result', 'force_result',
}
local PROTOCOL_ALLOWED = { name = true, _fibers_closure_protocol = true }
for i = 1, #PROTOCOL_FIELDS do PROTOCOL_ALLOWED[PROTOCOL_FIELDS[i]] = true end

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
    if not ok then error(err or message or 'closure operation failed', 0) end
    return true
  end
end

function Closure.protocol(protocol, label)
  local protocol_label = label or 'Closure protocol'
  if protocol == nil then
    protocol = { name = 'none', finish_op = function() return true_op() end }
  elseif type(protocol) ~= 'table' then
    error(protocol_label .. ' must be a protocol table', 3)
  end
  Contract.options(protocol, PROTOCOL_ALLOWED, protocol_label, 3)
  if protocol._fibers_closure_protocol ~= nil and protocol._fibers_closure_protocol ~= true then
    error(protocol_label .. ' has an invalid protocol marker', 3)
  end
  if protocol.name ~= nil and type(protocol.name) ~= 'string' then
    error(protocol_label .. ' name must be a string', 3)
  end
  local captured = capture_protocol(protocol, label)
  if type(captured.finish_op) ~= 'function' then
    error(protocol_label .. ' requires a finish_op function', 3)
  end
  return captured
end

function Closure.none()
  return Closure.protocol()
end

function Closure.request_then_wait(request_op, finish_op, opts)
  if type(request_op) ~= 'function' then error('request_then_wait expects request_op function', 2) end
  if type(finish_op) ~= 'function' then error('request_then_wait expects finish_op function', 2) end
  opts = Contract.options(opts, {
    name = true, force_op = true, request_result = true, finish_result = true, force_result = true,
  }, 'request_then_wait options', 2)
  if opts.name ~= nil then Contract.non_empty_string(opts.name, 'request_then_wait option name', 2) end
  Contract.optional_function(opts.force_op, 'request_then_wait force_op', 2)
  Contract.optional_function(opts.request_result, 'request_then_wait request_result', 2)
  Contract.optional_function(opts.finish_result, 'request_then_wait finish_result', 2)
  Contract.optional_function(opts.force_result, 'request_then_wait force_result', 2)
  local name = opts.name or 'request_then_wait'
  local function step(fn, field)
    return function(ctx, entry, close)
      return ensure_op(fn(ctx, entry, close and close.reason or nil, close), name .. '.' .. field)
    end
  end
  return Closure.protocol({
    name = name,
    request_op = step(request_op, 'request_op'),
    finish_op = step(finish_op, 'finish_op'),
    force_op = opts.force_op and step(opts.force_op, 'force_op') or nil,
    request_result = opts.request_result,
    finish_result = opts.finish_result,
    force_result = opts.force_result,
  })
end

function Closure.running()
  return Closure.request_then_wait(function(_ctx, entry, reason)
    if reason == Lifetime.CloseReason.NORMAL then return Op.always(true) end
    return entry.node:request_cancel_op(reason)
  end, function(_ctx, entry)
    local role = entry.node and entry.node:_scope_role(false)
    local done = role and (role.body_result or role.result)
    return done and done:success_op():map(function() return true end) or Op.always(true)
  end, { name = 'running_lifetime' })
end

-- CloseProcess --------------------------------------------------------------

local CloseProcess = {}
CloseProcess.__index = CloseProcess

local ClosureFailure = {}
ClosureFailure.__index = ClosureFailure

local function copy_progress(entries, public)
  local out = {}
  for i = 1, #(entries or {}) do
    local source = entries[i]
    local copy = public and { _fibers_value = true } or {}
    copy.item = source.item
    copy.request_state = source.request_state
    copy.request_error = source.request_error
    copy.force_state = source.force_state
    copy.force_error = source.force_error
    copy.close_state = source.close_state
    copy.closure_error = source.closure_error
    if source.close_state == 'succeeded' then
      copy.state = 'finished'
    elseif source.close_state == 'failed' then
      copy.state = 'finish_failed'
    elseif source.close_state == 'blocked' then
      copy.state = 'blocked_by_descendant'
    elseif source.force_state == 'failed' then
      copy.state = 'force_failed'
    elseif source.request_state == 'failed' then
      copy.state = 'request_failed'
    elseif source.force_state == 'succeeded' then
      copy.state = 'forced'
    elseif source.request_state == 'succeeded' then
      copy.state = 'requested'
    else
      copy.state = 'not_requested'
    end
    out[i] = copy
  end
  return out
end

local function process_new(ctx, claim, progress, progress_by_node)
  local result = Completion.new():label('closure-process-result')
  return setmetatable({
    _fibers_close_process = true,
    _fibers_value = true,
    _scope = ctx,
    _claim = claim,
    _result = result,
    _progress = progress,
    _progress_by_node = progress_by_node,
  }, CloseProcess)
end

local function completed_process(ctx, item)
  return setmetatable({
    _fibers_close_process = true,
    _fibers_value = true,
    _scope = ctx,
    _completed_item = item,
  }, CloseProcess)
end

function CloseProcess.is(value)
  return type(value) == 'table' and value._fibers_close_process == true
end

function CloseProcess:success_op()
  if self._completed_item ~= nil then return Op.always(self._completed_item) end
  return self._result:success_op()
end

function CloseProcess:failure_op()
  if self._completed_item ~= nil then return Op.never() end
  return self._result:failure_op()
end

function CloseProcess:result_op()
  return Op.choice(
    self:success_op():map(function(item) return true, item end),
    self:failure_op():map(function(failure) return false, failure end)
  )
end

local function closure_failure_message(process, failures, mark_error)
  local message = 'closure failed'
  local claim = process._claim
  local name = claim and item_label(claim.subject)
  if name ~= nil then message = message .. ' for ' .. tostring(name) end
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

function ClosureFailure.new(process, failures, mark_error)
  local first = failures and failures[1]
  local claim = process._claim
  local recovery = Counter.new(1):label('closure-recovery')
  local failure = setmetatable({
    _fibers_closure_failure = true,
    _fibers_value = true,
    kind = 'closure_failure',
    item = first and (Lifetime.of(first.item) or first.item) or claim.subject,
    custodian = claim.custodian,
    purpose = claim.purpose,
    reason = claim.reason,
    progress = copy_progress(process._progress, true),
    failures = failures or {},
    error = first and first.error or 'closure incomplete',
    mark_error = mark_error,
    _process = process,
    _recovery = recovery,
  }, ClosureFailure)
  failure.message = closure_failure_message(process, failures, mark_error)
  return failure
end

function ClosureFailure.is(value)
  return type(value) == 'table' and value._fibers_closure_failure == true
end

local drive_process
local StartCloseKind

local function start_effect(process, force)
  return Effect.of(StartCloseKind, { process = process, force = force == true })
end

StartCloseKind = Effect.kind({
  name = 'lifetime.start_close',
  key = function(payload) return payload.process end,
  merge = function()
    return Effect.reject({ kind = 'effect_conflict', message = 'duplicate closure process start' })
  end,
  prepare = function(_runtime, payload)
    if not CloseProcess.is(payload.process) or payload.process._completed_item ~= nil then
      return Effect.reject({ kind = 'effect_invalid', message = 'invalid closure process start' })
    end
    return {
      kind = StartCloseKind,
      key = payload.process,
      discharge = function(runtime)
        local process, force = payload.process, payload.force == true
        runtime:_spawn_committed(function()
          drive_process(process, force)
        end, process._scope, process._claim.subject)
        return true
      end,
    }
  end,
})

local function recovery_op(failure, force)
  if not ClosureFailure.is(failure) then error('closure recovery expects a Closure.Failure', 3) end
  local previous = failure._process
  if not CloseProcess.is(previous) or not previous._claim then
    error('Closure failure no longer has a recovery process', 3)
  end
  local process = process_new(previous._scope, previous._claim, previous._progress, previous._progress_by_node)
  return failure._recovery:read_op():and_then(Op.guard(function(available)
    if available < 1 then error('Closure failure no longer has recovery authority', 0) end
    return failure._recovery:take_op(1)
      :and_then(previous._scope:_store():_restart_close_claim_op(previous._claim, failure))
      :and_then(Op.emit(start_effect(process, force)))
      :map(function() return process end)
  end))
end

function ClosureFailure:retry_op()
  return recovery_op(self, false)
end

function ClosureFailure:force_op()
  return recovery_op(self, true)
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
    progress = copy_progress(self.progress),
    failures = failures, error = self.error, message = self.message,
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
Closure.Process = CloseProcess

-- Driver --------------------------------------------------------------------

local function protocol_for(claim_entry)
  return claim_entry.node._protocol
end

local function walk_preorder(entry, fn)
  fn(entry)
  for i = 1, #(entry.children or {}) do walk_preorder(entry.children[i], fn) end
end

local function process_trees(process)
  local claim = process._claim
  if claim.mode == 'subtree' then return { claim.tree } end
  return claim.trees or {}
end

local function ensure_progress(process)
  if process._progress then return process._progress end
  local progress, by_node = {}, {}
  local function add(claim_entry)
    local row = {
      _fibers_value = true,
      item = claim_entry.item,
      node = claim_entry.node,
      claim_entry = claim_entry,
      request_state = 'pending',
      force_state = 'pending',
      close_state = 'pending',
    }
    progress[#progress + 1] = row
    by_node[claim_entry.node] = row
  end
  local trees = process_trees(process)
  for i = 1, #trees do walk_preorder(trees[i], add) end
  process._progress, process._progress_by_node = progress, by_node
  return progress
end

local function step_context(process, phase)
  return {
    _fibers_value = true,
    root = process._claim.subject,
    reason = process._claim.reason,
    purpose = process._claim.purpose,
    phase = phase,
    forced = phase == 'force',
  }
end

local function run_step(ctx, process, entry, field, state_field, error_field, phase)
  local protocol = protocol_for(entry.claim_entry)
  local step = protocol[field]
  if step == nil then
    entry[state_field], entry[error_field] = 'succeeded', nil
    return true
  end
  local ok, err = Protected.pcall(function()
    local result = pack(perform_masked(ensure_op(
      step(ctx, entry.claim_entry, step_context(process, phase)),
      protocol.name .. '.' .. field
    )))
    local check_result = protocol[field:gsub('_op$', '_result')]
    if check_result then check_result(unpack_(result, 1, result.n)) end
    return unpack_(result, 1, result.n)
  end)
  if ok then
    entry[state_field], entry[error_field] = 'succeeded', nil
    return true
  end
  entry[state_field], entry[error_field] = 'failed', err
  return false, err
end

local function quiesce_pass(ctx, process, force)
  local field = force and 'force' or 'request'
  local progress = ensure_progress(process)
  for i = 1, #progress do
    local entry = progress[i]
    local state_field = field .. '_state'
    if entry.close_state ~= 'succeeded' and entry[state_field] ~= 'succeeded' then
      if not force or protocol_for(entry.claim_entry).force_op ~= nil then
        run_step(ctx, process, entry, field .. '_op', state_field, field .. '_error', field)
      end
    end
  end
end

local function children_finished(process, claim_entry)
  local by_node = process._progress_by_node or {}
  for i = 1, #(claim_entry.children or {}) do
    local child = by_node[claim_entry.children[i].node]
    if not child or child.close_state ~= 'succeeded' then return false end
  end
  return true
end

local function finish_pass(ctx, process)
  local progress = ensure_progress(process)
  for i = #progress, 1, -1 do
    local entry = progress[i]
    if entry.close_state ~= 'succeeded' then
      local quiesced = entry.request_state == 'succeeded' or entry.force_state == 'succeeded'
      if not quiesced then
        entry.close_state = 'pending'
      elseif not children_finished(process, entry.claim_entry) then
        entry.close_state = 'blocked'
      else
        entry.close_state = 'pending'
        run_step(ctx, process, entry, 'finish_op', 'close_state', 'closure_error', 'close')
      end
    end
  end
end

local FAILURE_PHASES = {
  { 'request_state', 'request', 'request_error' },
  { 'force_state', 'force', 'force_error' },
  { 'close_state', 'close', 'closure_error' },
}

local function collect_failures(process)
  local failures, progress = {}, process._progress or {}
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
        item = entry.item, phase = 'close', error = 'blocked by unresolved descendant', blocked = true,
      }
    end
  end
  return failures
end

local function process_finished(process)
  for i = 1, #(process._progress or {}) do
    if process._progress[i].close_state ~= 'succeeded' then return false end
  end
  return true
end

local function with_closure_authority(ctx, fn)
  require_context(ctx)
  ctx._closure_depth = (ctx._closure_depth or 0) + 1
  local ok, a, b, c = Protected.pcall(fn)
  ctx._closure_depth = ctx._closure_depth - 1
  if not ok then error(a, 0) end
  return a, b, c
end

local function containment_description(blocker)
  return 'closure retained ' .. tostring(blocker.count or 0) .. ' unresolved descendant(s) beneath '
    .. item_label(blocker.item or blocker.node)
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

local function publish_once(op, label)
  return op:map(function(published, err)
    if published ~= true then error((label or 'Closure result') .. ' was already published: ' .. tostring(err), 0) end
    return true
  end)
end

local function record_failure(process, failures)
  local failure = ClosureFailure.new(process, failures)
  local record = process._scope:_store():_fail_close_claim_op(process._claim, failure)
    :and_then(publish_once(process._result:publish_failure_op(failure), 'Closure failure'))
  local ok, err = Protected.pcall(function() perform_masked(record) end)
  if not ok then
    failure.mark_error = err
    failure.message = closure_failure_message(process, failures, err)
    error(failure.message, 0)
  end
  return failure
end

-- The closure fibre is runtime machinery for the already-accounted CloseClaim.
-- It never owns another Lifetime. All recoverable protocol failures are recorded
-- transactionally and then the fibre simply ends.
drive_process = function(process, force)
  local ctx = process._scope
  local ok, unexpected = Protected.pcall(function()
    ensure_progress(process)
    with_closure_authority(ctx, function()
      quiesce_pass(ctx, process, force == true)
      finish_pass(ctx, process)
    end)
  end)

  local failures = collect_failures(process)
  if not ok then
    failures[#failures + 1] = { item = process._claim.subject, phase = 'driver', error = unexpected }
  end
  if not ok or not process_finished(process) then
    record_failure(process, failures)
    return
  end

  local finish = ctx:_store():_discharge_close_claim_op(process._claim):and_then(Op.guard(function(discharged, blockers)
    if not discharged then return Op.always(false, blockers) end
    return publish_once(process._result:publish_success_op(item_of(process._claim.subject)), 'Closure success')
      :map(function() return true, nil end)
  end))
  local discharged, blockers = perform_masked(finish)
  if not discharged then record_failure(process, containment_failures(blockers)) end
end

-- Transactional initiation --------------------------------------------------

local function start_claim_op(ctx, claim)
  if claim._fibers_already_retired then return Op.always(completed_process(ctx, claim.item)) end
  local process = process_new(ctx, claim)
  return Op.emit(start_effect(process, false)):map(function() return process end)
end

function Closure.start_retire_op(ctx, item, reason)
  require_context(ctx)
  local purpose = { type = 'retire', reason = reason }
  return ctx:_store():_acquire_close_claim_op(ctx, item, purpose)
    :and_then(Op.guard(function(claim) return start_claim_op(ctx, claim) end))
end

-- Internal Scope operations intentionally expose delegation because an ancestor
-- may already own the overlapping structural responsibility.
function Closure._start_descendants_op(ctx, reason)
  require_context(ctx)
  local purpose = { type = 'drain_children', reason = reason }
  return ctx:_store():_acquire_descendants_claim_op(ctx, purpose):and_then(Op.guard(function(claim)
    if claim._fibers_already_retired then return Op.always('retired', nil) end
    if claim._fibers_close_delegated then return Op.always('delegated', nil) end
    local process = process_new(ctx, claim)
    return Op.emit(start_effect(process, false)):map(function() return 'started', process end)
  end))
end

function Closure._start_scope_op(ctx, item, reason)
  require_context(ctx)
  local purpose = { type = 'retire_scope', reason = reason, delegate_existing = true }
  return ctx:_store():_acquire_close_claim_op(ctx, item, purpose):and_then(Op.guard(function(claim)
    if claim._fibers_already_retired then return Op.always('retired', nil) end
    if claim._fibers_close_delegated then return Op.always('delegated', nil) end
    local process = process_new(ctx, claim)
    return Op.emit(start_effect(process, false)):map(function() return 'started', process end)
  end))
end

Direct.install(ClosureFailure, { 'retry', 'force' })
Direct.install(CloseProcess, { 'success', 'failure', 'result' })

return Closure

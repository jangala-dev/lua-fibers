-- Lifetime Closure boundary driver.
--
-- Child completion is committed directly into the current owning Lifetime.
-- There is no closure-monitor fiber and no separate custody event queue. Task and Scope
-- views share the same Lifetime node; Closure decisions are pure descriptions
-- which the driver applies through ordinary Ops.

local Runtime = require('fibers.runtime')
local Protected = require('fibers.protected')
local Exit = require('fibers.task').Exit
local ScopeOutcome = require('fibers.scope.outcome')
local ScopeResult = ScopeOutcome.Result
local Lifetime = require('fibers.lifetime')
local Op = require('fibers.op')
local Effect = require('fibers.effect')

local Driver = {}

-- Closure bookkeeping is retained ordinary state rather than transaction-managed
-- state.  Record it through a committed effect so request_cancel_op remains a
-- fully transactional Op: speculative exploration and losing branches leave the
-- Closure object untouched, while downstream and_then composition remains valid.
local CloseReasonKind
CloseReasonKind = Effect.kind({
  name = 'closure.close_reason',
  key = function(payload) return payload.state end,
  merge = function(a, b)
    return { state = a.state, reason = a.reason ~= nil and a.reason or b.reason }
  end,
  prepare = function(_runtime, payload)
    if type(payload.state) ~= 'table' then
      error('closure close-reason effect requires retained Closure state', 0)
    end
    return {
      kind = CloseReasonKind,
      key = payload.state,
      payload = payload,
      discharge = function(_rt, entry, _log)
        local state = entry.payload.state
        state.close_reason = state.close_reason or entry.payload.reason
      end,
    }
  end,
})

local function record_close_reason_effect(state, reason)
  return Effect.of(CloseReasonKind, { state = state, reason = reason })
end

local function pack(...)
  return { n = select('#', ...), ... }
end

local function tail_pack(p)
  local out = { n = math.max((p.n or #p) - 1, 0) }
  for i = 1, out.n do
    out[i] = p[i + 1]
  end
  return out
end

local function same_cancellation(a, b)
  return Runtime.is_cancelled
    and Runtime.is_cancelled(a)
    and Runtime.is_cancelled(b)
    and a.token == b.token
    and a.reason == b.reason
end

local function perform_masked(scope, op)
  local rt = scope._lifetime._runtime or Runtime.current()
  if not rt then
    error('masked scope option requires a current runtime', 2)
  end
  return rt:_perform_current(op, nil, true)
end

local function normalise_decision(decision, exit)
  if decision == nil then
    if Exit.is(exit) and exit.tag == 'failed' then
      return { fail_boundary = true, seal = true, cancel_body = true, cancel_children = true }
    end
    return {}
  end
  if Exit.is(decision) or decision == true then
    return { fail_boundary = true, seal = true, cancel_body = true, cancel_children = true }
  end
  if type(decision) ~= 'table' then
    return {}
  end
  return decision
end

local function call_closure(contract, name, scope, state, ...)
  local f = contract and contract[name]
  if type(f) ~= 'function' then
    return nil
  end
  return f(contract, scope, state, ...)
end

local function state_for(scope)
  local lifetime = scope and scope._lifetime
  if not lifetime then
    error('scope Closure requires a Scope Lifetime', 3)
  end
  return lifetime._closure_state
end

local function record_entry(state, child, exit)
  if state.processed[child] then
    return state.processed[child], false
  end
  state.sequence = state.sequence + 1
  local entry = {
    child = child,
    lifetime = child,
    exit = exit,
    sequence = state.sequence,
    decision_applied = false,
  }
  state.processed[child] = entry
  state.child_exits[#state.child_exits + 1] = entry
  if Exit.is(exit) and exit.tag == 'failed' then
    state.child_failures[#state.child_failures + 1] = entry
  end
  return entry, true
end

local function apply_decision(scope, state, decision, reason)
  decision = decision or {}
  if decision.fail_boundary and not state.first_child_failure then
    state.first_child_failure = state.child_failures[#state.child_failures]
  end
  if decision.seal or decision.cancel_body or decision.cancel_children then
    local close_reason = decision.reason or reason or 'scope Closure close'
    perform_masked(scope, scope:begin_close_op(close_reason, {
      cancel_body = decision.cancel_body == true,
      cancel_children = decision.cancel_children == true,
    }))
    state.close_reason = state.close_reason or close_reason
  end
end

local function apply_child_entry(scope, state, entry)
  if not entry or entry.decision_applied then
    return false
  end
  entry.decision_applied = true
  local exit = entry.exit
  local decision = normalise_decision(
    call_closure(state.closure, 'on_child_outcome', scope._lifetime, state, entry.lifetime, exit),
    exit
  )
  apply_decision(scope, state, decision, exit and (exit.error or exit.reason or exit) or nil)
  return true
end

function Driver.record_child_outcome(scope, child, exit, opts)
  if not scope or not scope._fibers_scope or not Lifetime.is(child) then
    return false
  end
  -- Custody at closure decides which Lifetime receives the consequence.
  local custodian = scope:_store():_custodian(child)
  if custodian ~= scope._lifetime then return false end
  local state = state_for(scope)
  local entry, fresh = record_entry(state, child, exit)
  if fresh and state.active and not (opts and opts.defer) then apply_child_entry(scope, state, entry) end
  return fresh, entry
end

function Driver.request_cancel_op(scope, reason)
  local state = state_for(scope)
  local decision = call_closure(scope._lifetime._closure, 'on_cancel_requested', scope._lifetime, state, reason)
    or { seal = true, cancel_children = true, reason = reason }
  local close_op
  if decision.seal or decision.cancel_children then
    close_op = scope:begin_close_op(decision.reason or reason, {
      cancel_body = false,
      cancel_children = decision.cancel_children == true,
    })
  end
  return scope:_request_cancel_op(reason):and_then(Op.guard(function(first, recorded_reason)
    if not first then
      return Op.always(false, recorded_reason)
    end
    if close_op then
      return close_op:and_then(Op.emit(record_close_reason_effect(
          state,
          decision.reason or recorded_reason
        )):map(function()
          return true, recorded_reason
        end))
    end
    return Op.always(true, recorded_reason)
  end))
end

local function retire_roots(scope, reason)
  local first_bad
  while true do
    local roots = perform_masked(scope, scope:_store():roots_op(scope))
    if #roots == 0 then
      break
    end
    local progressed = false
    for i = 1, #roots do
      local item = roots[i]
      if perform_masked(scope, scope:has_custody_op(item)) then
        local rec = perform_masked(scope, scope:_store():record_op(scope, item))
        local phase = rec and rec.phase
        if not rec then
          -- Custody changed between root discovery and record lookup; take another pass.
        elseif phase ~= 'live' then
          local err = rec.closure_error or ('cannot retire non-live root in phase ' .. tostring(phase))
          if not first_bad then
            first_bad = err
          end
        else
          local ok, err = Protected.pcall(function()
            perform_masked(scope, scope:close_op(item, reason))
          end)
          if not ok and not first_bad then
            first_bad = err
          end
          progressed = true
        end
      end
    end
    if first_bad or not progressed then
      break
    end
  end
  if first_bad then
    error(first_bad, 0)
  end
end

local function filter_duplicate_cancellation(primary, failures)
  if not (Runtime.is_cancelled and Runtime.is_cancelled(primary)) or #failures == 0 then
    return failures
  end
  local kept = {}
  for i = 1, #failures do
    if not same_cancellation(primary, failures[i]) then
      kept[#kept + 1] = failures[i]
    end
  end
  return kept
end

local function report_for(scope, primary, secondaries, fields)
  return scope:_make_report(primary, secondaries or {}, fields or {})
end

local function failed_result(scope, reason, primary, secondaries, fields, closure_failures)
  return ScopeResult.fail({
    reason = reason,
    primary = primary,
    report = report_for(scope, primary, secondaries, fields),
    closure_failures = closure_failures,
  })
end

local function default_result(scope, state, body_ok, body_results, closure_failures, close_reason)
  local body_primary = body_results[2]
  local child_entry = state.first_child_failure
  local child_exit = child_entry and child_entry.exit
  local child_primary = child_exit and (child_exit.error or child_exit.reason or child_exit) or nil
  local primary = body_primary
  local reason

  if child_primary and (body_ok or (Runtime.is_cancelled and Runtime.is_cancelled(body_primary))) then
    primary = child_primary
    reason = 'child_failed'
  elseif not body_ok then
    reason = Runtime.is_cancelled and Runtime.is_cancelled(body_primary) and 'cancelled' or 'body_error'
  elseif child_primary then
    primary = child_primary
    reason = 'child_failed'
  end

  closure_failures = filter_duplicate_cancellation(primary, closure_failures)
  local retained_closure_failures = {}
  local seen_closure_failures = {}
  ScopeOutcome.closure_failures(body_primary, retained_closure_failures, seen_closure_failures)
  ScopeOutcome.closure_failures(child_primary, retained_closure_failures, seen_closure_failures)
  for i = 1, #closure_failures do
    ScopeOutcome.closure_failures(closure_failures[i], retained_closure_failures, seen_closure_failures)
  end

  local secondaries = {}
  -- Collected and ignored child failures remain structured report facts,
  -- not secondary boundary failures. Once a child failure is selected as the
  -- boundary cause, additional failures are retained as secondaries.
  if state.first_child_failure then
    for i = 1, #state.child_failures do
      local entry = state.child_failures[i]
      local err = entry.exit and (entry.exit.error or entry.exit.reason or entry.exit)
      if err ~= primary then
        secondaries[#secondaries + 1] = err
      end
    end
  end
  for i = 1, #closure_failures do
    secondaries[#secondaries + 1] = closure_failures[i]
  end

  local fields = {
    reason = reason,
    closure_reason = close_reason,
    child_exits = state.child_exits,
    child_failures = state.child_failures,
    cause = state.first_child_failure,
    body_exit = ScopeOutcome.protected_exit(Exit, body_results),
    closure_failures = retained_closure_failures,
  }

  if reason then
    return failed_result(scope, reason, primary, secondaries, fields, retained_closure_failures)
  end
  if #closure_failures > 0 then
    local first = closure_failures[1]
    fields.reason = 'closure_failed'
    fields.message = 'scope closure failed: ' .. tostring(first)
    return failed_result(scope, 'closure_failed', first, secondaries, fields, retained_closure_failures)
  end
  return ScopeResult.ok(tail_pack(body_results), report_for(scope, nil, secondaries, fields))
end


local function result_exit(result)
  if not ScopeResult.is(result) then return Exit.returned(result) end
  if result.ok then return Exit.returned(result:unpack()) end
  if result.reason == 'cancelled' then
    local cancellation = result.primary
    if Runtime.is_cancelled and Runtime.is_cancelled(cancellation) then
      return Exit.cancelled(cancellation.reason, cancellation.token)
    end
    return Exit.cancelled(cancellation)
  end
  return Exit.failed(result.primary or result.report or result)
end

local function completed_exit(node)
  if not node or not node._has_body then return nil end
  local boundary = node._outcome and node._outcome._location.value
  if type(boundary) == 'table' and boundary.status == 'done' then
    return result_exit(boundary.result)
  end
  local body = node._body_result and node._body_result._location.value
  return type(body) == 'table' and body.status == 'done' and Exit.is(body.result) and body.result or nil
end

local function account_existing_children(scope, state)
  local roots = scope:_store():_roots(scope)
  for i = 1, #roots do
    local node = roots[i]
    local exit = completed_exit(node)
    if exit then
      local entry = record_entry(state, node, exit)
      apply_child_entry(scope, state, entry)
    end
  end
  for i = 1, #state.child_exits do apply_child_entry(scope, state, state.child_exits[i]) end
end

local function stage_custodian_outcome(scope, result)
  local custodian = scope:_store():_custodian(scope._lifetime)
  if not custodian or custodian == scope._lifetime then return nil end
  local parent = require('fibers.scope').for_lifetime(custodian)
  local fresh, entry = Driver.record_child_outcome(
    parent,
    scope._lifetime,
    result_exit(result),
    { defer = true }
  )
  if not fresh then return nil end
  return { parent = parent, entry = entry }
end

local function capture_failure(out, fn)
  local ok, err = Protected.pcall(fn)
  if not ok then out[#out + 1] = err end
end

function Driver.run(scope, fn, closure, on_body_exit)
  if type(fn) ~= 'function' then
    error('Scope:run expects a function', 2)
  end
  if on_body_exit ~= nil and type(on_body_exit) ~= 'function' then
    error('Scope closure body-exit hook must be a function or nil', 2)
  end
  local rt = scope._lifetime._runtime or Runtime.current()
  if not rt then
    error('Scope:run requires a current runtime', 2)
  end
  scope._lifetime:_bind_runtime(rt)
  scope._lifetime._closure = closure

  local state = state_for(scope)
  state.active = true
  state.closure = closure

  local fiber = assert(rt._current_fiber, 'Scope:run requires a current fiber')
  local previous_scope = fiber.scope
  fiber.scope = scope
  local setup_ok, setup_err = Protected.pcall(function()
    account_existing_children(scope, state)
  end)

  local body_results
  if setup_ok then
    body_results = pack(Protected.pcall(fn, scope))
  else
    body_results = pack(false, setup_err)
  end
  if on_body_exit ~= nil then
    local published, publish_err = Protected.pcall(on_body_exit, body_results, rt)
    if not published then
      fiber.scope = previous_scope
      error(publish_err, 0)
    end
  end

  local body_ok = body_results[1]
  local body_primary = body_results[2]
  local close_reason = body_ok and Lifetime.CloseReason.NORMAL or body_primary
  local closure_failures = {}

  capture_failure(closure_failures, function()
    local decision = call_closure(closure, 'on_body_result', scope._lifetime, state, body_ok, body_primary)
      or (body_ok and { seal = true } or { seal = true, cancel_children = true })
    if decision.seal or decision.cancel_children then
      perform_masked(scope, scope:begin_close_op(decision.reason or close_reason, {
        cancel_body = false,
        cancel_children = decision.cancel_children == true,
      }))
    end
  end)
  capture_failure(closure_failures, function() retire_roots(scope, close_reason) end)

  state.active = false

  local result = default_result(scope, state, body_ok, body_results, closure_failures, close_reason)
  local staged
  local stage_ok, stage_err = Protected.pcall(function()
    staged = stage_custodian_outcome(scope, result)
  end)
  if not stage_ok and result.ok then
    result = failed_result(scope, 'closure_contract_failed', stage_err, {},
      { reason = 'closure_contract_failed' })
    staged = nil
  end

  -- Publish complete closure before applying parent propagation. A parent may
  -- begin settling this child as soon as propagation requests closure; making
  -- the outcome visible first prevents the parent from waiting on a fact which
  -- this child has not yet had an opportunity to publish.
  local mark_ok, mark_err = Protected.pcall(function()
    perform_masked(scope, scope:_mark_done_op(result))
  end)
  if not mark_ok then
    result = failed_result(scope, 'closure_failed', mark_err, {}, { reason = 'done_mark_failed' })
  elseif staged then
    local apply_ok, apply_err = Protected.pcall(function()
      apply_child_entry(staged.parent, state_for(staged.parent), staged.entry)
    end)
    if not apply_ok and result.ok then
      result = failed_result(scope, 'closure_contract_failed', apply_err, {},
        { reason = 'closure_contract_failed' })
      -- The published outcome remains the original value. Contract functions
      -- are required to be pure and non-throwing; this branch is diagnostic.
    end
  end

  fiber.scope = previous_scope
  return result
end

function Driver.try_run(scope, fn)
  return Driver.run(scope, fn, scope._lifetime._closure or {})
end

function Driver.run_raising(scope, fn)
  return Driver.try_run(scope, fn):raise()
end

return Driver

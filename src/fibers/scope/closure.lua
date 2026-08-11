-- Scope supervision and execution driver.
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
local LifetimeClosure = require('fibers.internal.lifetime.closure')
local Op = require('fibers.op')

local Driver = {}

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
  -- Supervision accounting belongs to the Scope role, not the generic
  -- Lifetime. All Scope views over one Lifetime share this role.
  local role = lifetime:_scope_role(true)
  local state = role.driver_state
  if not state then
    state = { processed = {}, child_exits = {}, child_failures = {} }
    role.driver_state = state
  end
  return state
end

local function record_entry(state, child, exit)
  if state.processed[child] then
    return state.processed[child], false
  end
  local entry = {
    child = child,
    lifetime = child,
    exit = exit,
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
  end
end

local function apply_child_entry(scope, state, entry)
  if not entry or entry.decision_applied then
    return false
  end
  entry.decision_applied = true
  local exit = entry.exit
  local decision = normalise_decision(
    call_closure(scope._role.policy, 'on_child_outcome', scope._lifetime, state, entry.lifetime, exit),
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
  -- Constructing cancellation is inert. Supervision state is allocated only by
  -- an active Scope driver or child-outcome accounting, never merely because a
  -- cancellation Option was described or explored and defeated.
  return Op.guard(function()
    local state = scope._role.driver_state or {
      processed = {}, child_exits = {}, child_failures = {},
    }
    local decision = call_closure(scope._role.policy, 'on_cancel_requested', scope._lifetime, state, reason)
      or { seal = true, cancel_children = true, reason = reason }
    local close_op
    if decision.seal or decision.cancel_children then
      close_op = scope:begin_close_op(decision.reason or reason, {
        cancel_body = false,
        cancel_children = decision.cancel_children == true,
      })
    end
    return scope:_request_cancel_op(reason):and_then(Op.guard(function(first, recorded_reason)
      if not first then return Op.always(false, recorded_reason) end
      if close_op then
        return close_op:map(function() return true, recorded_reason end)
      end
      return Op.always(true, recorded_reason)
    end))
  end)
end

local function await_owned_execution_results(scope)
  local children = perform_masked(scope, scope:_store():children_op(scope))
  local waits = {}
  for i = 1, #children do
    local node = Lifetime.of(children[i])
    if node then
      local role = node:_scope_role(false)
      local body, result = role and role.body_result, role and role.result
      if body then
        -- Body completion proves the Task driver has installed its Scope result.
        waits[#waits + 1] = body:success_op():and_then(Op.guard(function()
          return role.result and role.result:success_op() or Op.always(true)
        end))
      elseif result then
        waits[#waits + 1] = result:success_op()
      end
    end
  end
  if #waits > 0 then perform_masked(scope, Op.each(waits)) end
end

local function await_close_process(scope, process)
  local ok, result = perform_masked(scope, process:result_op())
  if not ok then error(result, 0) end
  return result
end

local function retire_owned(scope, reason)
  local mode, process = perform_masked(scope, LifetimeClosure._start_descendants_op(scope, reason))
  if mode == 'started' then
    await_close_process(scope, process)
  elseif mode == 'delegated' then
    -- The overlapping ancestor CloseClaim owns structural retirement. This
    -- Scope still waits for execution results needed by supervision, but never
    -- competes for those Lifetimes structurally.
    await_owned_execution_results(scope)
  end
  return mode
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
  -- not secondary supervision failures. Once a child failure is selected as the
  -- Scope cause, additional failures are retained as secondaries.
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
  if not node or node:_task() == nil then return nil end
  local terminal = node._outcome and node._outcome._location.value
  if type(terminal) == 'table' and terminal.kind == 'succeeded' then
    local values = terminal.values or {}
    return result_exit(values[1])
  end
  local role = node:_scope_role(false)
  local body = role and role.body_result and role.body_result._location.value
  if type(body) == 'table' and body.kind == 'succeeded' then
    local value = (body.values or {})[1]
    return Exit.is(value) and value or nil
  end
  return nil
end

local function account_existing_children(scope, state)
  local children = scope:_store():_children(scope)
  for i = 1, #children do
    local node = children[i]
    local exit = completed_exit(node)
    if exit then
      local entry = record_entry(state, node, exit)
      apply_child_entry(scope, state, entry)
    end
  end
  for i = 1, #state.child_exits do apply_child_entry(scope, state, state.child_exits[i]) end
end

local function stage_custodian_outcome(scope, result)
  -- Custody and supervision are distinct. Task-backed Lifetimes report their
  -- execution outcome to the custodian's supervision policy. A lexical Scope is
  -- synchronously observed through try_scope/scope and must not fail its parent
  -- a second time merely because the parent owns its Lifetime.
  if scope._lifetime:_task() == nil then return nil end
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
  scope._role.policy = closure or {}
  scope:_result_completion()

  local state = state_for(scope)
  state.active = true

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
  -- Structural retirement has one authority: CloseClaim/CloseProcess. A Scope
  -- acquires one children-drain claim for its complete owned subtree; if an
  -- ancestor already owns an overlapping claim this operation observes
  -- delegation transactionally instead of racing child-by-child closure.
  capture_failure(closure_failures, function()
    retire_owned(scope, close_reason)
    account_existing_children(scope, state)
  end)

  state.active = false

  local result = default_result(scope, state, body_ok, body_results, closure_failures, close_reason)
  local staged
  local stage_ok, stage_err = Protected.pcall(function()
    staged = stage_custodian_outcome(scope, result)
  end)
  if not stage_ok and result.ok then
    result = failed_result(scope, 'supervision_failed', stage_err, {},
      { reason = 'supervision_failed' })
    staged = nil
  end

  -- The accounted Scope result is published before retirement. Retirement itself
  -- always belongs to CloseClaim/CloseProcess: either this Scope claims its now
  -- quiescent Lifetime through its custodian, or an overlapping ancestor claim
  -- already owns that responsibility.
  local mark_ok, mark_err = Protected.pcall(function()
    perform_masked(scope, scope:_settle_done_op(result))
    -- Execution settlement and structural retirement are distinct. Ordinary
    -- Task Lifetimes and successful resource drivers may discharge a quiescent
    -- node through the custodian. An abnormal domain-resource driver leaves
    -- structural cleanup to its custodian so cleanup failure is reported by the
    -- owner rather than stranding a self-held recovery claim inside the failed
    -- execution.
    local kind = scope._role.execution_kind
    local self_retires = kind == nil or kind == 'task' or body_ok == true
    if self_retires
      and not (ScopeResult.is(result) and result.closure_failures and #result.closure_failures > 0) then
      local parent = scope:parent_scope()
      if parent then
        local mode, process = perform_masked(scope, LifetimeClosure._start_scope_op(parent, scope._lifetime, close_reason))
        if mode == 'started' then await_close_process(scope, process) end
      end
    end
  end)
  if not mark_ok then
    result = failed_result(scope, 'closure_failed', mark_err, {}, { reason = 'done_mark_failed' })
  elseif staged then
    local apply_ok, apply_err = Protected.pcall(function()
      apply_child_entry(staged.parent, state_for(staged.parent), staged.entry)
    end)
    if not apply_ok and result.ok then
      result = failed_result(scope, 'supervision_failed', apply_err, {},
        { reason = 'supervision_failed' })
    end
  end

  fiber.scope = previous_scope
  return result
end

function Driver.try_run(scope, fn)
  return Driver.run(scope, fn, scope._role.policy or {})
end

return Driver

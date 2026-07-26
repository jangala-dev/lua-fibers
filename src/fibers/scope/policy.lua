-- Policy-owned Scope boundary driver.
--
-- Built-in policies use this driver, but a policy may provide its own try_run
-- method and use these mechanisms selectively.  The Region remains the source
-- of custody truth; the monitor observes task roots without becoming an owned
-- task itself.

local Runtime = require('fibers.runtime')
local Protected = require('fibers.internal.protected')
local Exit = require('fibers.task').Exit
local ScopeResult = require('fibers.scope.result')
local Settlement = require('fibers.region.settlement')
local Op = require('fibers.op')
local Scalar = require('fibers.resource.scalar')
local Task = require('fibers.task')

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
  local rt = scope.runtime or Runtime.current()
  if not rt then
    error('masked scope option requires a current runtime', 2)
  end
  return rt:_perform_current(op, nil, true)
end

local function monitor_perform(op)
  local rt = Runtime.current()
  if not rt then
    error('scope policy monitor requires a current runtime', 2)
  end
  return rt:_perform_current(op, nil, true)
end

local function is_requested(value)
  return type(value) == 'table' and (value.requested == true or value.cancelled == true)
end

local function cancellation_reason(value)
  return type(value) == 'table' and value.reason or nil
end

local function normalise_decision(decision, exit)
  if decision == nil then
    if Exit.is(exit) and exit.tag == 'failed' then
      return { fail_boundary = true, seal = true, cancel_body = true, cancel_children = true }
    end
    return {}
  end
  if Exit.is(decision) then
    return { fail_boundary = true, seal = true, cancel_body = true, cancel_children = true }
  end
  if decision == true then
    return { fail_boundary = true, seal = true, cancel_body = true, cancel_children = true }
  end
  if type(decision) ~= 'table' then
    return {}
  end
  return decision
end

local function call_policy(policy, name, scope, state, ...)
  local f = policy and policy[name]
  if type(f) ~= 'function' then
    return nil
  end
  return f(policy, scope, state, ...)
end

local function record_child_exit(state, task, exit)
  if state.processed[task] then
    return nil
  end
  state.sequence = state.sequence + 1
  local entry = { task = task, exit = exit, sequence = state.sequence }
  state.processed[task] = entry
  state.child_exits[#state.child_exits + 1] = entry
  if Exit.is(exit) and exit.tag == 'failed' then
    state.child_failures[#state.child_failures + 1] = entry
  end
  return entry
end

local function apply_decision(scope, state, decision, reason)
  decision = decision or {}
  if decision.fail_boundary and not state.first_child_failure then
    state.first_child_failure = state.child_failures[#state.child_failures]
  end
  if decision.seal or decision.cancel_body or decision.cancel_children then
    local close_reason = decision.reason or reason or 'scope policy close'
    monitor_perform(scope:begin_close_op(close_reason, {
      cancel_body = decision.cancel_body == true,
      cancel_children = decision.cancel_children == true,
    }))
    state.close_reason = state.close_reason or close_reason
  end
end

local function changed_event_op(resource, version, typ)
  return resource:changed_op(version):map(function()
    return { type = typ }
  end)
end

local function is_task(item)
  return type(item) == 'table' and item._fibers_obligation_kind == 'task'
end

local function add_active_task(scope, state, task)
  if not is_task(task) or state.active[task] then
    return
  end
  state.active[task] = true
  if state.processed[task] then
    return
  end
  local exit = task.completion and task.completion.value or nil
  if Exit.is(exit) then
    local entry = record_child_exit(state, task, exit)
    if entry then
      local decision =
        normalise_decision(call_policy(state.policy, 'on_child_exit', scope, state, task, exit), exit)
      apply_decision(scope, state, decision, exit.error or exit.reason or exit)
    end
  else
    state.pending_count = state.pending_count + 1
  end
end

local function remove_active_task(state, task)
  if not state.active[task] then
    return
  end
  state.active[task] = nil
  if not state.processed[task] then
    state.pending_count = math.max(state.pending_count - 1, 0)
  end
end

local function record_active_exit(scope, state, task, exit)
  if not state.active[task] or state.processed[task] then
    return
  end
  local owns = task.owner == scope.region
  if not owns then
    remove_active_task(state, task)
    return
  end
  local entry = record_child_exit(state, task, exit)
  if not entry then
    return
  end
  state.pending_count = math.max(state.pending_count - 1, 0)
  local decision =
    normalise_decision(call_policy(state.policy, 'on_child_exit', scope, state, task, exit), exit)
  apply_decision(scope, state, decision, exit.error or exit.reason or exit)
end

local function apply_lifetime_event(scope, state, event)
  if type(event) ~= 'table' then
    return
  end
  local typ = event.type
  local task = event.task or event.item
  if typ == 'admitted' then
    if event.to == scope.region then
      add_active_task(scope, state, task)
    end
  elseif typ == 'moved' then
    if event.from == scope.region then
      remove_active_task(state, task)
    end
    if event.to == scope.region then
      add_active_task(scope, state, task)
    end
  elseif typ == 'released' then
    if event.from == scope.region then
      remove_active_task(state, task)
    end
  elseif typ == 'task_exit' and is_task(task) then
    record_active_exit(scope, state, task, event.exit)
  end
end

local function monitor_loop(scope, state, policy)
  state.policy = policy
  for task, record in pairs(scope.region.owned or {}) do
    if record.parent == nil then
      add_active_task(scope, state, task)
    end
  end

  while true do
    local body = monitor_perform(state.body_done:snapshot_op())
    local cancellation = monitor_perform(scope.cancellation:snapshot_op())

    if is_requested(cancellation.value) and not state.cancel_seen then
      state.cancel_seen = true
      state.cancel_reason = cancellation_reason(cancellation.value)
      local decision = call_policy(policy, 'on_cancel_requested', scope, state, state.cancel_reason)
        or { seal = true, cancel_children = true }
      apply_decision(scope, state, decision, state.cancel_reason)
    end

    local body_is_done = type(body.value) == 'table' and body.value.done == true
    if body_is_done and state.pending_count == 0 then
      return state
    end

    local choices = {
      scope._lifetime_events:_drain_op():map(function(events)
        return { type = 'lifetime_events', events = events }
      end),
      changed_event_op(state.body_done, body.version, 'body_done'),
    }
    if not state.cancel_seen then
      choices[#choices + 1] = changed_event_op(scope.cancellation, cancellation.version, 'cancel_requested')
    end

    local event = monitor_perform(Op.choice(choices))
    if event.type == 'lifetime_events' then
      for i = 1, #(event.events or {}) do
        local packed = event.events[i]
        apply_lifetime_event(scope, state, type(packed) == 'table' and packed[1] or packed)
      end
    end
  end
end

function Driver.start_monitor(scope, state, policy, rt)
  if state.monitor then
    return state.monitor
  end
  rt = rt or scope.runtime or Runtime.current()
  local monitor = Task.new(function()
    return monitor_loop(scope, state, policy)
  end, scope.name .. '-policy-monitor', scope)
  state.monitor = monitor
  monitor:_start_internal(rt, scope)
  return monitor
end

function Driver.seal(scope, reason)
  return perform_masked(scope, scope:seal_op(reason))
end

function Driver.begin_close(scope, reason, opts)
  return perform_masked(scope, scope:begin_close_op(reason, opts))
end

local function retire_roots(scope, reason)
  local first_bad
  while true do
    local roots = perform_masked(scope, scope:roots_op())
    if #roots == 0 then
      break
    end
    local progressed = false
    for i = 1, #roots do
      local item = roots[i]
      if perform_masked(scope, scope:owns_op(item)) then
        local rec = perform_masked(scope, scope:record_op(item))
        local phase = rec and rec.phase
        if not rec then
          -- Ownership changed between roots_op and record_op; take another pass.
        elseif phase ~= 'live' then
          local err = rec.settlement_error or ('cannot retire non-live root in phase ' .. tostring(phase))
          if not first_bad then
            first_bad = err
          end
        else
          local ok, err = Protected.pcall(function()
            perform_masked(scope, Settlement.retire_item_op(scope, item, reason))
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

function Driver.retire_roots(scope, reason)
  return retire_roots(scope, reason)
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

local function append_settlement_failures(out, value, seen)
  if type(value) ~= 'table' then
    return
  end
  seen = seen or {}
  if seen[value] then
    return
  end
  seen[value] = true

  if value._fibers_settlement_failure == true then
    out[#out + 1] = value
    return
  end

  local failures = value.settlement_failures
  if type(failures) == 'table' then
    for i = 1, #failures do
      append_settlement_failures(out, failures[i], seen)
    end
  end
  local secondaries = value.secondaries
  if type(secondaries) == 'table' then
    for i = 1, #secondaries do
      append_settlement_failures(out, secondaries[i], seen)
    end
  end
  append_settlement_failures(out, value.report, seen)
  append_settlement_failures(out, value.primary, seen)
  append_settlement_failures(out, value.cause, seen)
end

local function default_result(scope, policy, state, body_ok, body_results, settlement_failures, close_reason)
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

  settlement_failures = filter_duplicate_cancellation(primary, settlement_failures)
  local retained_settlement_failures = {}
  local seen_settlement_failures = {}
  append_settlement_failures(retained_settlement_failures, body_primary, seen_settlement_failures)
  append_settlement_failures(retained_settlement_failures, child_primary, seen_settlement_failures)
  for i = 1, #settlement_failures do
    append_settlement_failures(retained_settlement_failures, settlement_failures[i], seen_settlement_failures)
  end

  local secondaries = {}
  for i = 1, #state.child_failures do
    local entry = state.child_failures[i]
    local err = entry.exit and (entry.exit.error or entry.exit.reason or entry.exit)
    if err ~= primary then
      secondaries[#secondaries + 1] = err
    end
  end
  for i = 1, #settlement_failures do
    secondaries[#secondaries + 1] = settlement_failures[i]
  end

  local fields = {
    reason = reason,
    closure_reason = close_reason,
    child_exits = state.child_exits,
    child_failures = state.child_failures,
    cause = state.first_child_failure,
    body_exit = { ok = body_ok, primary = body_primary },
    settlement_failures = retained_settlement_failures,
  }

  local custom = call_policy(policy, 'result', scope, state, {
    body_ok = body_ok,
    body_results = body_results,
    primary = primary,
    reason = reason,
    secondaries = secondaries,
    settlement_failures = retained_settlement_failures,
    close_reason = close_reason,
    fields = fields,
  })
  if ScopeResult.is(custom) then
    return custom
  end

  if reason then
    return ScopeResult.fail({
      reason = reason,
      primary = primary,
      report = report_for(scope, primary, secondaries, fields),
      settlement_failures = retained_settlement_failures,
    })
  end
  if #settlement_failures > 0 then
    local first = settlement_failures[1]
    fields.reason = 'settlement_failed'
    fields.message = 'scope settlement failed: ' .. tostring(first)
    return ScopeResult.fail({
      reason = 'settlement_failed',
      primary = first,
      report = report_for(scope, first, secondaries, fields),
      settlement_failures = retained_settlement_failures,
    })
  end
  return ScopeResult.ok(tail_pack(body_results), report_for(scope, nil, secondaries, fields))
end

function Driver.run(scope, fn, policy)
  if type(fn) ~= 'function' then
    error('Scope:run expects a function', 2)
  end
  local rt = scope.runtime or Runtime.current()
  if not rt then
    error('Scope:run requires a current runtime', 2)
  end
  scope.runtime = rt

  local state = {
    body_done = Scalar.new({ done = false }, scope.name .. '-body-done'),
    processed = {},
    active = {},
    pending_count = 0,
    child_exits = {},
    child_failures = {},
    sequence = 0,
  }

  local token = rt.push_scope and rt:push_scope(scope) or nil
  scope._policy_state = state
  scope._ensure_policy_monitor = function(sc, event_rt)
    return Driver.start_monitor(sc, state, policy, event_rt or rt)
  end
  for item, record in pairs(scope.region.owned or {}) do
    if record.parent == nil and is_task(item) then
      Driver.start_monitor(scope, state, policy, rt)
      break
    end
  end

  local body_results = pack(Protected.pcall(fn, scope))
  local body_ok = body_results[1]
  local body_primary = body_results[2]
  local close_reason = body_ok and 'scope_exit' or body_primary
  local settlement_failures = {}

  local close_ok, close_err = Protected.pcall(function()
    local decision = call_policy(policy, 'on_body_exit', scope, state, body_ok, body_primary)
    if decision == nil then
      decision = body_ok and { seal = true } or { seal = true, cancel_children = true }
    end
    if decision.seal or decision.cancel_children then
      Driver.begin_close(scope, decision.reason or close_reason, {
        cancel_body = false,
        cancel_children = decision.cancel_children == true,
      })
    end
  end)
  if not close_ok then
    settlement_failures[#settlement_failures + 1] = close_err
  end

  local done_ok, done_err = Protected.pcall(function()
    perform_masked(scope, state.body_done:write_op({ done = true, ok = body_ok, primary = body_primary }))
  end)
  if not done_ok then
    settlement_failures[#settlement_failures + 1] = done_err
  end

  if state.monitor then
    local monitor_ok, monitor_exit = Protected.pcall(function()
      return perform_masked(scope, state.monitor:exit_op())
    end)
    if not monitor_ok then
      settlement_failures[#settlement_failures + 1] = monitor_exit
    elseif Exit.is(monitor_exit) and monitor_exit.tag == 'failed' then
      settlement_failures[#settlement_failures + 1] = monitor_exit.error
    end
  end
  scope._ensure_policy_monitor = nil
  scope._policy_state = nil

  local settle_ok, settle_err = Protected.pcall(function()
    retire_roots(scope, close_reason)
  end)
  if not settle_ok then
    settlement_failures[#settlement_failures + 1] = settle_err
  end

  local result =
    default_result(scope, policy, state, body_ok, body_results, settlement_failures, close_reason)
  local mark_ok, mark_err = Protected.pcall(function()
    perform_masked(scope, scope:_mark_done_op(result))
  end)
  if not mark_ok then
    result = ScopeResult.fail({
      reason = 'settlement_failed',
      primary = mark_err,
      report = report_for(scope, mark_err, {}, { reason = 'done_mark_failed' }),
    })
  end

  local pop_ok, pop_err = true, nil
  if token and rt.pop_scope then
    pop_ok, pop_err = Protected.pcall(function()
      return rt:pop_scope(token)
    end)
  end
  if not pop_ok then
    result = ScopeResult.fail({
      reason = result.ok and 'settlement_failed' or result.reason,
      primary = result.ok and pop_err or result.primary,
      report = report_for(scope, result.primary or pop_err, { pop_err }, { reason = 'scope_pop_failed' }),
    })
  end
  return result
end

function Driver.try_run(scope, fn)
  local policy = scope.policy
  if policy and type(policy.try_run) == 'function' then
    return policy:try_run(scope, fn, Driver)
  end
  return Driver.run(scope, fn, policy or {})
end

function Driver.run_raising(scope, fn)
  return Driver.try_run(scope, fn):raise()
end

return Driver

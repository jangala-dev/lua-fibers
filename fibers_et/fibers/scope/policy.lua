-- Default Scope policy driver.
--
-- Scope exposes the lifetime calculus. This helper interprets the ordinary
-- strict settlement policy and returns a ScopeResult rather than treating scope
-- lifecycle as mutable status.

local Runtime = require('fibers.kernel.runtime')
local Protected = require('fibers.kernel.protected')
local Exit = require('fibers.kernel.exit')
local ScopeResult = require('fibers.kernel.scope_result')
local Settlement = require('fibers.internal.settlement')
local Op = require('fibers.atoms.op')

local Policy = {}

local function pack(...) return { n = select('#', ...), ... } end
local function tail_pack(p)
  local out = { n = math.max((p.n or #p) - 1, 0) }
  for i = 1, out.n do out[i] = p[i + 1] end
  return out
end

local function same_cancellation(a, b)
  return Runtime.is_cancelled and Runtime.is_cancelled(a) and Runtime.is_cancelled(b) and a.token == b.token and a.reason == b.reason
end

local function is_task(item)
  return type(item) == 'table' and item._fibers_obligation_kind == 'task'
end

local function call_policy(scope, name, ...)
  local policy = scope.policy
  local f = policy and policy[name]
  if type(f) ~= 'function' then return nil end
  return f(policy, scope, ...)
end

local function perform_masked(scope, op)
  return scope:mask(function() return scope:perform(op) end)
end

local function request_cancel_item_op(scope, item, reason)
  return scope:record_op(item):and_then(function(record)
    if not record then return Op.always(false) end
    if type(item.request_cancel_op) == 'function' then
      return item:request_cancel_op(reason):map(function() return true end)
    elseif type(item.shutdown_op) == 'function' then
      return item:shutdown_op(reason):map(function() return true end)
    end
    return Op.always(false)
  end)
end

local function request_cancel_roots(scope, reason)
  local roots = perform_masked(scope, scope:roots_op())
  for i = 1, #roots do
    local item = roots[i]
    if perform_masked(scope, scope:owns_op(item)) then
      perform_masked(scope, request_cancel_item_op(scope, item, reason))
    end
  end
end

local function live_task_roots(scope, observed)
  local roots = perform_masked(scope, scope:roots_op())
  local out = {}
  for i = 1, #roots do
    local item = roots[i]
    if is_task(item) and not observed[item] and perform_masked(scope, scope:owns_op(item)) then
      local rec = perform_masked(scope, scope:record_op(item))
      if rec and rec.phase == 'live' then
        out[#out + 1] = { item = item, record = rec }
      end
    end
  end
  return out
end

local function task_exit_choice_op(entries)
  local choices = {}
  for i = 1, #entries do
    local item = entries[i].item
    choices[#choices + 1] = item:exit_op():map(function(exit)
      return item, exit
    end)
  end
  if #choices == 0 then return Op.always(nil, nil) end
  return Op.choice(choices)
end

local function exit_is_cancelled(_scope, _item, exit)
  return Exit.is(exit) and exit.tag == 'cancelled'
end

local function await_task_roots(scope)
  local observed = {}
  while true do
    local entries = live_task_roots(scope, observed)
    if #entries == 0 then return nil end

    local item, exit = perform_masked(scope, task_exit_choice_op(entries))
    if not item then return nil end
    observed[item] = true

    if not exit_is_cancelled(scope, item, exit) then
      local policy_err = call_policy(scope, 'on_child_exit', item, exit)
      if policy_err then return policy_err end
      if Exit.is(exit) and exit.tag == 'failed' then return exit end
    end
  end
end

local function retire_roots(scope, reason)
  local first_bad
  while true do
    local roots = perform_masked(scope, scope:roots_op())
    if #roots == 0 then break end
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
          if not first_bad then first_bad = err end
        else
          local ok, err = Protected.pcall(function()
            perform_masked(scope, Settlement.retire_item_op(scope, item, reason))
          end)
          if not ok and not first_bad then first_bad = err end
          progressed = true
        end
      end
    end
    if first_bad or not progressed then break end
  end
  if first_bad then error(first_bad, 0) end
end

local function filter_duplicate_cancellation(primary, failures)
  if not (Runtime.is_cancelled and Runtime.is_cancelled(primary)) or #failures == 0 then return failures end
  local kept = {}
  for i = 1, #failures do
    if not same_cancellation(primary, failures[i]) then kept[#kept + 1] = failures[i] end
  end
  return kept
end

local function report_for(scope, primary, secondaries, fields)
  return scope:_make_report(primary, secondaries or {}, fields or {})
end

local function result_from(scope, body_ok, body_results, primary, child_bad, settlement_failures, close_reason)
  settlement_failures = filter_duplicate_cancellation(primary, settlement_failures)
  if not body_ok then
    local report = (#settlement_failures > 0) and report_for(scope, primary, settlement_failures, { reason = close_reason }) or nil
    local reason = Runtime.is_cancelled and Runtime.is_cancelled(primary) and 'cancelled' or 'body_error'
    return ScopeResult.fail({ reason = reason, primary = primary, report = report })
  end
  if child_bad then
    local child_primary = child_bad.error or child_bad.reason or child_bad
    local report = report_for(scope, child_primary, settlement_failures, { reason = 'child_failed', child = child_bad })
    return ScopeResult.fail({ reason = 'child_failed', primary = child_primary, report = report })
  end
  if #settlement_failures > 0 then
    local report = report_for(scope, nil, settlement_failures, { reason = close_reason, message = 'scope settlement failed: ' .. tostring(settlement_failures[1]) })
    return ScopeResult.fail({ reason = 'settlement_failed', primary = settlement_failures[1], report = report })
  end
  return ScopeResult.ok(tail_pack(body_results), report_for(scope, nil, {}, { reason = close_reason }))
end

function Policy.try_run(scope, fn)
  if type(fn) ~= 'function' then error('Scope:run expects a function', 2) end
  local rt = scope.runtime or Runtime.current()
  if not rt then error('Scope:run requires a current runtime', 2) end
  scope.runtime = rt
  local token = rt.push_scope and rt:push_scope(scope) or nil
  local results = pack(Protected.pcall(fn, scope))
  local ok = results[1]
  local primary = results[2]
  local settlement_failures = {}
  local child_bad

  local close_reason = ok and 'scope_exit' or primary
  local settled_ok, settled_err = Protected.pcall(function()
    call_policy(scope, 'on_scope_closing', close_reason, ok, primary)
    perform_masked(scope, scope:seal_op(close_reason))
    if not ok then
      local handled = call_policy(scope, 'on_body_failure', primary)
      if handled == nil then request_cancel_roots(scope, primary) end
    end
    child_bad = await_task_roots(scope)
    if child_bad then
      local reason = child_bad.error or child_bad.reason or child_bad
      local handled = call_policy(scope, 'on_child_failure', reason, child_bad)
      if handled == nil then request_cancel_roots(scope, reason) end
    end
    retire_roots(scope, close_reason)
  end)
  if not settled_ok then settlement_failures[#settlement_failures + 1] = settled_err end

  local result = result_from(scope, ok, results, primary, child_bad, settlement_failures, close_reason)
  local mark_ok, mark_err = Protected.pcall(function() perform_masked(scope, scope:_mark_done_op(result)) end)
  if not mark_ok then
    result = ScopeResult.fail({ reason = 'settlement_failed', primary = mark_err, report = report_for(scope, mark_err, {}, { reason = 'done_mark_failed' }) })
  end

  local pop_ok, pop_err = true, nil
  if token and rt.pop_scope then pop_ok, pop_err = Protected.pcall(function() return rt:pop_scope(token) end) end
  if not pop_ok then
    result = ScopeResult.fail({ reason = result.ok and 'settlement_failed' or result.reason, primary = result.ok and pop_err or result.primary, report = report_for(scope, result.primary or pop_err, { pop_err }, { reason = 'scope_pop_failed' }), values = result.values })
  end

  return result
end

function Policy.run(scope, fn)
  return Policy.try_run(scope, fn):raise()
end

return Policy

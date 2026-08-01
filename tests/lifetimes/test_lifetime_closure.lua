package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

local fibers = require('fibers')
local Op = require('fibers.op')
local Lifetime = require('fibers.lifetime')
local Closure = require('fibers.closure')

local function eq(a, b, msg)
  if a ~= b then
    error((msg or 'assertion failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2)
  end
end
local function truthy(v, msg)
  if not v then
    error(msg or 'expected truthy', 2)
  end
end

local function protocol(name, log, opts)
  opts = opts or {}
  return Closure.protocol({
    name = name,
    request_op = function()
      log[#log + 1] = 'request ' .. name
      return Op.always(true)
    end,
    finish_op = function()
      log[#log + 1] = 'finish ' .. name
      if opts.fail and not opts.recovered then
        error(name .. ' closure failed', 0)
      end
      return Op.always(true)
    end,
    force_op = function()
      log[#log + 1] = 'force ' .. name
      opts.recovered = true
      return Op.always(true)
    end,
  })
end

local function resource(name, log, children, opts)
  local value = { name = name }
  Lifetime.define(value, {
    name = name,
    closure = protocol(name, log, opts),
    children = children,
  })
  return value
end

-- Requests are parent-first and closure is child-first with reverse sibling
-- order. Final closure retires the complete subtree atomically.
do
  local log = {}
  local a1 = resource('a1', log)
  local a = resource('a', log, { a1 })
  local b = resource('b', log)
  local root = resource('root', log, { a, b })
  fibers.run(function(scope)
    fibers.perform(scope:admit_op(root))
  end)
  local expected = {
    'request root',
    'request a',
    'request a1',
    'request b',
    'finish b',
    'finish a1',
    'finish a',
    'finish root',
  }
  eq(#log, #expected)
  for i = 1, #expected do
    eq(log[i], expected[i], 'closure order at ' .. i)
  end
  eq(Lifetime.of(root):current_state().closure_phase, 'closed')
end

-- A failed closure retains completed progress and an exclusive recovery
-- capability. Force retries unresolved nodes without repeating settled siblings.
do
  local log, bad_opts = {}, { fail = true }
  local good = resource('good', log)
  local bad = resource('bad', log, nil, bad_opts)
  local root = resource('failure-root', log, { bad, good })
  local result = fibers.try_run(function(scope)
    fibers.perform(scope:admit_op(root))
  end)
  eq(result.ok, false)
  eq(result.reason, 'closure_failed')
  local failure = result.closure_failure
  truthy(Closure.is_failure(failure), 'failure must retain recovery authority')
  eq(failure._token, nil, 'the internal close token must not be exposed')
  local inspection = failure:inspect()
  eq(inspection.kind, 'closure_failure')
  truthy(#inspection.progress > 0, 'closure inspection should retain progress')
  local good_count = 0
  for i = 1, #log do
    if log[i] == 'finish good' then
      good_count = good_count + 1
    end
  end
  eq(good_count, 1)

  local pair = Op.together({ failure:force_op(), failure:force_op() }):or_else(Op.always('fallback'))
  local pair_result = fibers.run(function()
    return fibers.perform(pair)
  end)
  eq(pair_result, 'fallback', 'two recoveries cannot share one transactional authority')

  local recovery = failure:force_op()
  local duplicate = failure:force_op()
  fibers.run(function()
    fibers.perform(recovery)
  end)
  local duplicate_ok = pcall(function()
    fibers.run(function()
      fibers.perform(duplicate)
    end)
  end)
  eq(duplicate_ok, false, 'a committed recovery must consume the old capability')
  eq(
    pcall(function()
      failure:retry_op()
    end),
    false,
    'a completed recovery must not be reusable'
  )
  good_count = 0
  for i = 1, #log do
    if log[i] == 'finish good' then
      good_count = good_count + 1
    end
  end
  eq(good_count, 1, 'completed sibling must not finish twice')
  eq(Lifetime.of(root):current_state().closure_phase, 'closed')
end

-- Complete containment is enforced by the store. A running child whose own
-- boundary retains a failed descendant remains under the parent in
-- closure_failed state. Recovering the descendant and then the parent close
-- token retires the complete subtree without losing custody in between.
do
  local log, bad_opts = {}, { fail = true }
  local task, child_scope, bad
  local result = fibers.try_run(function(scope)
    task = fibers.perform(scope:spawn_op(function(child)
      child_scope = child
      bad = resource('nested-bad', log, nil, bad_opts)
      fibers.perform(child:admit_op(bad))
      return 'body-complete'
    end, { name = 'nested-child' }))
    fibers.perform(task:outcome_op())
  end)

  eq(result.ok, false)
  eq(result.reason, 'child_failed')
  local task_state = task:lifetime():current_state()
  eq(task_state.closure_phase, 'closure_failed')
  truthy(task_state.custodian ~= nil, 'failed child Lifetime must retain parent custody')
  eq(Lifetime.of(bad):current_state().closure_phase, 'closure_failed')
  eq(#child_scope:_store():current_records(child_scope, false), 1)

  local nested_failure, parent_failure
  for i = 1, #(result.closure_failures or {}) do
    local f = result.closure_failures[i]
    if f.item == Lifetime.of(bad) then
      nested_failure = f
    end
    if f.item == task:lifetime() then
      parent_failure = f
    end
  end
  truthy(nested_failure, 'nested closure failure must remain recoverable')
  truthy(parent_failure, 'parent containment failure must remain recoverable')
  local parent_inspection = parent_failure:inspect()
  local blocker = parent_inspection.failures[1] and parent_inspection.failures[1].blocker
  truthy(
    blocker and #blocker.descendants > 0,
    'containment diagnostics should identify unresolved descendants'
  )
  truthy(
    string.find(blocker.descendants[1].path or '', 'nested%-bad') ~= nil,
    'containment diagnostics should include the custody path'
  )

  fibers.run(function()
    nested_failure:force()
  end)
  eq(Lifetime.of(bad):current_state().closure_phase, 'closed')
  eq(#child_scope:_store():current_records(child_scope, false), 0)
  eq(task:lifetime():current_state().closure_phase, 'closure_failed')

  fibers.run(function()
    parent_failure:retry()
  end)
  task_state = task:lifetime():current_state()
  eq(task_state.closure_phase, 'closed')
  eq(task_state.custodian, nil)
end

-- Facility callbacks receive a bounded Closure context, never the exclusive
-- close token used by the engine.
do
  local observed
  local value = { name = 'closure-context' }
  Lifetime.define(value, {
    closure = Closure.protocol({
      name = 'closure-context',
      finish_op = function(_scope, _record, close)
        observed = close
        return Op.always(true)
      end,
    }),
  })
  fibers.run(function(scope)
    fibers.perform(scope:admit_op(value))
  end)
  truthy(observed and observed.reason ~= nil, 'Closure context should include the reason')
  eq(observed._fibers_close_token, nil, 'Closure callbacks must not receive the close token')
  eq(observed.phase, 'close')
end

-- Low-level state marking is private runtime machinery rather than ordinary
-- Lifetime capability surface.
do
  local node = Lifetime.new('private-transition-surface')
  eq(node.mark_closed_op, nil)
  eq(node.mark_closure_failed_op, nil)
  eq(node.closing_op, nil)
end

print('tests/lifetimes/test_lifetime_closure.lua: ok')

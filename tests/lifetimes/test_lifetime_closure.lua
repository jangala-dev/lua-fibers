package.path = table.concat({
  './src/?.lua', './src/?/init.lua', './src/?/?.lua',
  './?.lua', './?/init.lua', './?/?.lua', package.path,
}, ';')

local fibers = require('fibers')
local Op = require('fibers.op')
local Lifetime = require('fibers.lifetime')
local Lifetimes = require('tests.support.lifetimes')
local Closure = require('fibers.closure')

local function eq(a, b, msg)
  if a ~= b then error((msg or 'assertion failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2) end
end
local function truthy(v, msg) if not v then error(msg or 'expected truthy', 2) end end

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
      if opts.fail and not opts.recovered then error(name .. ' closure failed', 0) end
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
    label = name,
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
  fibers.run(function(scope) fibers.perform(scope:admit_op(root)) end)
  local expected = {
    'request root', 'request a', 'request a1', 'request b',
    'finish b', 'finish a1', 'finish a', 'finish root',
  }
  eq(#log, #expected)
  for i = 1, #expected do eq(log[i], expected[i], 'closure order at ' .. i) end
  eq(Lifetimes.state(root).phase, 'retired')
end

-- A failed closure retains completed progress and an exclusive recovery
-- capability. Force retries unresolved nodes without repeating settled siblings.
do
  local log, bad_opts = {}, { fail = true }
  local good = resource('good', log)
  local bad = resource('bad', log, nil, bad_opts)
  local root = resource('failure-root', log, { bad, good })
  local result = fibers.try_run(function(scope) fibers.perform(scope:admit_op(root)) end)
  eq(result.ok, false)
  eq(result.reason, 'closure_failed')
  local failure = result.closure_failure
  truthy(Closure.Failure.is(failure), 'failure must retain recovery authority')
  eq(failure._token, nil, 'the internal close claim must not be exposed')
  local inspection = failure:inspect()
  eq(inspection.kind, 'closure_failure')
  truthy(#inspection.progress > 0, 'closure inspection should retain progress')
  local good_count = 0
  for i = 1, #log do if log[i] == 'finish good' then good_count = good_count + 1 end end
  eq(good_count, 1)

  local pair = Op.together({ failure:force_op(), failure:force_op() }):or_else(Op.always('fallback'))
  local pair_result = fibers.run(function() return fibers.perform(pair) end)
  eq(pair_result, 'fallback', 'two recoveries cannot share one transactional authority')

  local Cell = require('fibers.resource.cell')
  local recovery = failure:force_op()
  local duplicate = failure:force_op()
  fibers.run(function()
    local marker = Cell.new('failed')
    local process = fibers.perform(recovery:and_then(Op.guard(function(p)
      return marker:write_op('recovering'):map(function() return p end)
    end)))
    eq(fibers.perform(marker:read_op()), 'recovering', 'recovery remains transactionally sequenceable')
    local ok, closed = fibers.perform(process:result_op())
    eq(ok, true)
    truthy(closed, 'successful recovery process should publish its structural subject')
  end)
  local duplicate_ok = pcall(function()
    fibers.run(function() fibers.perform(duplicate) end)
  end)
  eq(duplicate_ok, false, 'a committed recovery must consume the old capability')
  local stale_ok = pcall(function()
    fibers.run(function() fibers.perform(failure:retry_op()) end)
  end)
  eq(stale_ok, false, 'a completed recovery must not be reusable')
  good_count = 0
  for i = 1, #log do if log[i] == 'finish good' then good_count = good_count + 1 end end
  eq(good_count, 1, 'completed sibling must not finish twice')
  eq(Lifetimes.state(root).phase, 'retired')
end

-- Closure failure remains attached to the Lifetime whose local protocol failed.
-- Ancestors remain CLOSING while that responsibility is unresolved, but do not
-- manufacture a second containment-recovery capability. Recover the actual
-- failure, then close the ancestor normally once its child set is empty.
do
  local log, bad_opts = {}, { fail = true }
  local task, child_scope, bad
  local result = fibers.try_run(function(scope)
    task = fibers.perform(scope:spawn_op(function(child)
      child_scope = child
      bad = resource('nested-bad', log, nil, bad_opts)
      fibers.perform(child:admit_op(bad))
      return 'body-complete'
    end, { label = 'nested-child' }))
    fibers.perform(task:outcome_op())
  end)

  eq(result.ok, false)
  eq(result.reason, 'child_failed')
  local task_state = Lifetimes.state(task:lifetime())
  eq(task_state.phase, 'closing')
  truthy(task_state.closure_fault ~= nil, 'ancestor records the unresolved closure fault')
  truthy(task_state.custodian ~= nil, 'failed child Lifetime must retain parent custody')
  local bad_state = Lifetimes.state(bad)
  eq(bad_state.phase, 'closing')
  truthy(bad_state.closure_fault ~= nil, 'the failing Lifetime records its closure fault')
  eq(#child_scope:_store():_children(child_scope), 1)

  local nested_failure
  for i = 1, #(result.closure_failures or {}) do
    local f = result.closure_failures[i]
    if f.item == Lifetime.of(bad) then nested_failure = f end
  end
  truthy(nested_failure, 'the actual closure failure must remain recoverable')
  eq(#(result.closure_failures or {}), 1, 'containment must not duplicate recovery authority')

  fibers.run(function()
    local process = nested_failure:force()
    local ok = process:result()
    eq(ok, true)
  end)
  eq(Lifetimes.state(bad).phase, 'retired')
  eq(#child_scope:_store():_children(child_scope), 0)
  eq(Lifetimes.state(task:lifetime()).phase, 'closing')

  fibers.run(function()
    result.scope:retire(task, 'nested-recovered')
  end)
  task_state = Lifetimes.state(task:lifetime())
  eq(task_state.phase, 'retired')
  eq(task_state.custodian, nil)
end

-- Facility callbacks receive a bounded Closure context, never the exclusive
-- close claim used by the engine.
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
  eq(observed._fibers_close_claim, nil, 'Closure callbacks must not receive the close claim')
  eq(observed.phase, 'close')
end



-- Low-level state marking is private runtime machinery rather than ordinary
-- Lifetime capability surface.
do
  local node = Lifetime.new():label('private-transition-surface')
  eq(node.mark_closed_op, nil)
  eq(node.mark_closure_failed_op, nil)
  eq(node.closing_op, nil)
end

print('tests/lifetimes/test_lifetime_closure.lua: ok')

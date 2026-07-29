package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './reference/?.lua',
  './reference/?/init.lua',
  './reference/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

local fibers = require('fibers')
local Lifetime = require('fibers.lifetime')
local Closure = require('fibers.closure')

local function fail(msg)
  error(msg, 2)
end
local function assert_eq(a, b, msg)
  if a ~= b then
    fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a))
  end
end
local function assert_truthy(v, msg)
  if not v then
    fail(msg or 'expected truthy')
  end
end

-- run and scope are value-returning lifetime boundaries.
do
  local a, b, c = fibers.run(function()
    return 'a', nil, 'c'
  end)
  assert_eq(a, 'a')
  assert_eq(b, nil)
  assert_eq(c, 'c')
end

-- try_run and try_scope expose the account explicitly without raising for
-- ordinary lifetime failure.
do
  local r = fibers.try_run(function()
    return fibers.try_scope(function()
      return 1, nil, 3
    end)
  end)
  assert_truthy(r.ok, 'try_run should succeed')
  local inner = r.values[1]
  assert_truthy(inner and inner.ok, 'try_scope should return a ScopeResult')
  local a, b, c = inner:unpack()
  assert_eq(a, 1)
  assert_eq(b, nil)
  assert_eq(c, 3)
end

-- done_op is a boundary fact. It reports the accounted outcome, not the body
-- return values.
do
  local outcome
  fibers.run(function()
    local inner
    local r = fibers.try_scope(function(scope)
      inner = scope
      return 'value'
    end)
    assert_truthy(r.ok, 'inner scope should succeed')
    outcome = fibers.perform(inner:done_op())
  end)
  assert_truthy(outcome and outcome.ok == true, 'done_op should resolve to successful outcome')
  assert_eq(outcome.reason, nil)
end

-- Root body success does not hide an owned child failure.
do
  local r = fibers.try_run(function()
    fibers.spawn(function()
      error('child boom', 0)
    end)
  end)
  assert_eq(r.ok, false)
  assert_eq(r.reason, 'child_failed')
  assert_truthy(
    tostring(r.primary):match('child boom') or tostring(r.report):match('child boom'),
    'child failure should be reported'
  )

  local ok, err = pcall(function()
    fibers.run(function()
      fibers.spawn(function()
        error('child boom', 0)
      end)
    end)
  end)
  assert_eq(ok, false)
  assert_truthy(tostring(err):match('child boom'), 'raising run should surface child failure')
end

-- Body values are not returned if Closure fails after body success.
do
  local r = fibers.try_run(function()
    fibers.scope(function(scope)
      local h = { name = 'failing-settle' }
      Lifetime.define(
        h,
        {
          closure = {
            name = 'fail',
            finish_op = function()
              error('closure failed', 0)
            end,
          },
        }
      )
      fibers.perform(scope:admit_op(h))
      return 'body-value'
    end)
  end)
  assert_eq(r.ok, false)
  assert_truthy(r.reason == 'body_error' or r.reason == 'closure_failed')
  assert_truthy(tostring(r.report or r.primary):match('closure failed'), 'closure failure should be reported')
  assert_truthy(Closure.is_failure(r.closure_failure), 'checked result should retain recovery authority')
  assert_eq(r.closure_failures[1], r.closure_failure)
  assert_eq(r.report.closure_failures[1], r.closure_failure)
  assert_eq(r.report.closure_failure_count, 1)
end

print('tests/test_scope_result_run.lua: ok')

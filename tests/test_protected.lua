-- Tests for yieldable protected calls.
--
-- This file does not alter module or global state.  The forced coroutine-backed
-- path is exercised by tests/run_protected_fallback.lua in a fresh interpreter.

local function fail(msg)
  error(msg, 2)
end
local function eq(a, b, msg)
  if a ~= b then
    fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a))
  end
end
local function ok(v, msg)
  if not v then
    fail(msg or 'expected truthy')
  end
end
local function test(_name, fn)
  fn()
end

local fibers = require('fibers')
local Protected = require('fibers.internal.protected')

local expected_native = rawget(_G, '__FIBERS_PROTECTED_EXPECT_NATIVE')
if expected_native ~= nil then
  test('selected protected-call path matches the isolated runner', function()
    eq(Protected.using_native(), expected_native)
  end)
end

test('fibers.pcall permits perform to suspend and resume', function()
  local protected_ok, got
  local st = fibers.try_run(function()
    local ch = fibers.Rendezvous.new('protected-rendezvous')
    fibers.spawn(function()
      fibers.perform(ch:put_op('hello'))
    end, 'sender')

    protected_ok, got = fibers.pcall(function()
      return fibers.perform(ch:get_op())
    end)
  end).runtime_status

  eq(st.tag, 'found')
  eq(protected_ok, true)
  eq(got, 'hello')
end)

test('fibers.pcall catches ordinary fibre errors', function()
  local protected_ok, err
  local st = fibers.try_run(function()
    protected_ok, err = fibers.pcall(function()
      error('protected boom', 0)
    end)
  end).runtime_status

  ok(st.tag == 'idle' or st.tag == 'found', 'expected idle or found, got: ' .. tostring(st.tag))
  eq(protected_ok, false)
  ok(tostring(err):match('protected boom'), 'expected protected error, got: ' .. tostring(err))
end)

test('fibers.xpcall permits perform and handles errors', function()
  local sync_ok, got, err_ok, handled
  local st = fibers.try_run(function()
    local ch = fibers.Rendezvous.new('protected-xrendezvous')
    fibers.spawn(function()
      fibers.perform(ch:put_op('x'))
    end, 'sender')

    sync_ok, got = fibers.xpcall(function()
      return fibers.perform(ch:get_op())
    end, function(err)
      return 'handled:' .. tostring(err)
    end)

    err_ok, handled = fibers.xpcall(function()
      error('xboom', 0)
    end, function(err)
      return 'handled:' .. tostring(err)
    end)
  end).runtime_status

  eq(st.tag, 'found')
  eq(sync_ok, true)
  eq(got, 'x')
  eq(err_ok, false)
  ok(
    tostring(handled):match('handled:.*xboom'),
    'expected handled xboom, got: ' .. tostring(handled)
  )
end)

test('task bodies may perform while protected for result reporting', function()
  local value
  local st = fibers.try_run(function()
    local region = fibers.Region.new('protected-region')
    local task = fibers.perform(fibers.Task.spawn_op(region, function()
      return fibers.perform(fibers.Op.always('task-ok'))
    end, 'protected-task'))
    value = fibers.perform(task:await_op())
  end).runtime_status

  eq(st.tag, 'found')
  eq(value, 'task-ok')
end)

print('tests/test_protected.lua: ok')

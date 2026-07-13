-- Runtime host, phase and error contract tests.
package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

local Op = require('fibers.atoms.op')
local Runtime = require('fibers.kernel.runtime')
local Scalar = require('fibers.atoms.scalar')
local TC = require('tests.effect_helpers')

local function update_scalar(scalar, fn)
  return scalar:read_op():and_then(function(old)
    local new = fn(old)
    return scalar:write_op(new):map(function()
      return new, old
    end)
  end)
end

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
local function assert_error_kind(ok, err, kind, msg)
  if ok then
    fail((msg or 'expected error') .. ': call succeeded')
  end
  if type(err) ~= 'table' or err.kind ~= kind then
    fail(
      (msg or 'wrong error kind')
        .. ': expected '
        .. tostring(kind)
        .. ', got '
        .. tostring(type(err) == 'table' and err.kind or err)
    )
  end
end

-- rt:now uses the injected host clock.
do
  local clock = 12.5
  local rt = Runtime.new({ host = {
    now = function()
      return clock
    end,
  } })
  assert_eq(rt:now(), 12.5, 'initial host clock')
  clock = 99
  assert_eq(rt:now(), 99, 'updated host clock')
end

-- Phase helper preserves arbitrary arity, including nils, without result packing.
do
  local rt = Runtime.new()
  local a, b, c, d, e, f = rt:_call_in_phase('contract-test-phase', 'callback_error', function(x)
    assert_eq(rt._phase, 'contract-test-phase', 'phase visible inside helper')
    return x, nil, 'c', 'd', false, 'f'
  end, 'a')
  assert_eq(rt._phase, 'external', 'phase restored after helper')
  assert_eq(a, 'a', 'phase helper return 1')
  assert_eq(b, nil, 'phase helper return 2 nil')
  assert_eq(c, 'c', 'phase helper return 3')
  assert_eq(d, 'd', 'phase helper return 4')
  assert_eq(e, false, 'phase helper return 5 false')
  assert_eq(f, 'f', 'phase helper return 6')
end

-- perform is only legal from a resumed runtime fibre.
do
  local rt = Runtime.new()
  local ok, err = pcall(function()
    return rt:perform(Op.always('x'))
  end)
  assert_error_kind(ok, err, 'phase_error', 'perform outside fibre')
end

-- perform inside guard is rejected because guard runs during search.
do
  local rt = Runtime.new()
  rt:spawn_raw(function()
    rt:perform(Op.guard(function()
      return rt:perform(Op.always('bad'))
    end))
  end, 'guard-performer')
  local ok, err = pcall(function()
    rt:run()
  end)
  assert_error_kind(ok, err, 'phase_error', 'perform inside guard')
end

-- perform inside map is rejected because map runs during candidate evaluation.
do
  local rt = Runtime.new()
  rt:spawn_raw(function()
    rt:perform(Op.always('x'):map(function(v)
      return v .. rt:perform(Op.always('bad'))
    end))
  end, 'map-performer')
  local ok, err = pcall(function()
    rt:run()
  end)
  assert_error_kind(ok, err, 'phase_error', 'perform inside map')
end

-- perform inside and_then is rejected because and_then extends the same candidate world.
do
  local rt = Runtime.new()
  rt:spawn_raw(function()
    rt:perform(Op.always('x'):and_then(function(v)
      rt:perform(Op.always('bad'))
      return Op.always(v)
    end))
  end, 'and_then-performer')
  local ok, err = pcall(function()
    rt:run()
  end)
  assert_error_kind(ok, err, 'phase_error', 'perform inside and_then')
end

-- Spawn is allowed from external driver code and from a resumed fibre, but not
-- from runtime internals.
do
  local rt = Runtime.new()
  local child_ran = false
  rt:spawn_raw(function()
    rt:spawn_raw(function()
      child_ran = true
    end, 'spawned-from-fibre-child')
  end, 'spawned-from-fibre-parent')
  rt:run()
  assert_eq(child_ran, true, 'spawn from resumed fibre is allowed')
end

-- spawn inside guard is rejected because guard is runtime search work, not external code.
do
  local rt = Runtime.new()
  rt:spawn_raw(function()
    rt:perform(Op.guard(function()
      rt:spawn_raw(function() end, 'bad-spawn')
      return Op.always('x')
    end))
  end, 'guard-spawner')
  local ok, err = pcall(function()
    rt:run()
  end)
  assert_error_kind(ok, err, 'phase_error', 'spawn inside guard')
  assert_eq(rt._driver_depth or 0, 0, 'driver depth reset after caught phase error')
  local ok_spawn = pcall(function()
    rt:spawn_raw(function() end, 'external-spawn-after-guard-error')
  end)
  assert_eq(ok_spawn, true, 'external spawn is not blocked after caught phase error')
end

-- Effect handlers run after commit.  If they fail, the transaction is
-- already committed, so the runtime is marked fatally failed rather than trying
-- to recover.
do
  local rt
  rt = Runtime.new({
    host = {
      test_tag = function()
        rt:perform(Op.always('bad'))
      end,
    },
  })
  rt:spawn_raw(function()
    rt:perform(Op.emit(TC.kind('contract-test')))
  end, 'effect-performer')
  local ok, err = pcall(function()
    rt:run()
  end)
  assert_error_kind(
    ok,
    err,
    'effect_error',
    'perform inside effect handler is fatal effect failure'
  )
  assert_eq(err.committed, true, 'effect failure records that commit already happened')
  assert_eq(err.fatal, true, 'effect failure is fatal')
  assert_eq(rt:failed(), err, 'runtime stores fatal effect error')
  assert_eq(rt._phase, 'external', 'effect phase restored after handler error')
  local ok_spawn, spawn_err = pcall(function()
    rt:spawn_raw(function() end, 'after-fatal')
  end)
  assert_error_kind(
    ok_spawn,
    spawn_err,
    'effect_error',
    'failed runtime rejects later spawn with fatal error'
  )
end

-- wrap runs in the resumed fibre and may perform a fresh post-commit transaction.
do
  local rt = Runtime.new()
  local got
  rt:spawn_raw(function()
    got = rt:perform(Op.always('x'):wrap(function(v)
      return v .. rt:perform(Op.always('y'))
    end))
  end, 'wrap-performer')
  local st = rt:run()
  assert_eq(st.tag, 'found', 'wrap perform run status')
  assert_eq(got, 'xy', 'wrap may perform')
end

-- step and run are external driver calls, not fibre calls.
do
  local rt = Runtime.new()
  local step_ok, step_err, run_ok, run_err
  rt:spawn_raw(function()
    step_ok, step_err = pcall(function()
      return rt:step()
    end)
    run_ok, run_err = pcall(function()
      return rt:run()
    end)
  end, 'driver-guard')
  rt:run()
  assert_error_kind(step_ok, step_err, 'phase_error', 'step inside fibre')
  assert_error_kind(run_ok, run_err, 'phase_error', 'run inside fibre')
end

-- A wrap failure happens after commit and must not roll back committed resources.
do
  local scalar = Scalar.new(0, 'wrap-error-scalar')
  local rt = Runtime.new()
  rt:spawn_raw(function()
    rt:perform(scalar:write_op(1):wrap(function()
      error('wrap exploded')
    end))
  end, 'wrap-error')
  local ok, _err = pcall(function()
    rt:run()
  end)
  assert_eq(ok, false, 'wrap error should escape the driver by default')
  assert_eq(scalar.value, 1, 'wrap error does not roll back commit')
end

-- A raw error inside guard should not leave the runtime believing that an
-- external caller is still inside driver internals.
do
  local rt = Runtime.new()
  rt:spawn_raw(function()
    rt:perform(Op.guard(function()
      error('boom')
    end))
  end, 'guard-raw-error')
  local ok, err = pcall(function()
    rt:run()
  end)
  assert_error_kind(ok, err, 'callback_error', 'raw guard error is structured')
  assert_eq(rt._driver_depth or 0, 0, 'driver depth reset after raw guard error')
  local ok_spawn = pcall(function()
    rt:spawn_raw(function() end, 'external-after-raw-guard-error')
  end)
  assert_eq(ok_spawn, true, 'external spawn is not blocked after raw guard error')
end

-- Raw map/and_then callback errors are also reported as callback errors without
-- poisoning later external calls.
do
  local rt = Runtime.new()
  rt:spawn_raw(function()
    rt:perform(Op.always('x'):map(function()
      error('map boom')
    end))
  end, 'map-raw-error')
  local ok, err = pcall(function()
    rt:run()
  end)
  assert_error_kind(ok, err, 'callback_error', 'raw map error is structured')
  assert_eq(rt._driver_depth or 0, 0, 'driver depth reset after raw map error')
  local ok_spawn = pcall(function()
    rt:spawn_raw(function() end, 'external-after-raw-map-error')
  end)
  assert_eq(ok_spawn, true, 'external spawn is not blocked after raw map error')
end

-- A raw effect handler error is also fatal and prevents later driver use.
do
  local scalar = Scalar.new(0, 'fatal-effect-scalar')
  local rt = Runtime.new()
  rt:spawn_raw(function()
    rt:perform(Op.emit(TC.discharge_fatal()):and_then(function()
      return scalar:write_op(1)
    end))
  end, 'raw-effect-error')
  local ok, err = pcall(function()
    rt:run()
  end)
  assert_error_kind(ok, err, 'effect_error', 'raw effect error is fatal')
  assert_eq(err.committed, true, 'raw effect error is after commit')
  assert_eq(err.fatal, true, 'raw effect error marks runtime fatal')
  assert_eq(scalar.value, 1, 'raw effect error does not roll back committed resource')
  local ok_run, run_err = pcall(function()
    rt:run()
  end)
  assert_error_kind(ok_run, run_err, 'effect_error', 'failed runtime rejects later run')
end

-- An uncaught phase error from a fibre must not leave later external calls
-- misclassified as runtime-internal calls.
do
  local rt = Runtime.new()
  rt:spawn_raw(function()
    rt:run()
  end, 'fibre-calls-run')
  local ok, err = pcall(function()
    rt:run()
  end)
  assert_error_kind(ok, err, 'phase_error', 'run inside fibre escapes as phase error')
  assert_eq(rt._driver_depth or 0, 0, 'driver depth restored after fibre phase error')
  assert_eq(rt._phase, 'external', 'phase restored after fibre phase error')
  local ok_spawn = pcall(function()
    rt:spawn_raw(function() end, 'external-after-fibre-phase-error')
  end)
  assert_eq(ok_spawn, true, 'external spawn after fibre phase error is allowed')
end

-- Scalar updates expressed as algebra protect user callback errors
-- callback errors rather than trusted resource-protocol failures.
do
  local scalar = Scalar.new(0, 'derived-update-error-scalar')
  local rt = Runtime.new()
  rt:spawn_raw(function()
    rt:perform(update_scalar(scalar, function()
      error('scalar update exploded')
    end))
  end, 'derived-update-error')
  local ok, err = pcall(function()
    rt:run()
  end)
  assert_error_kind(ok, err, 'callback_error', 'derived update error is a protected callback error')
  assert_eq(rt._driver_depth or 0, 0, 'driver depth restored after derived callback error')
  assert_eq(rt._phase, 'external', 'phase restored after derived callback error')
end

print('tests/test_contracts.lua: ok')

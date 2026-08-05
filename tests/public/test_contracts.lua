-- Runtime host, phase and error contract tests.
package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local Cell = require('fibers.resource.cell')
local TC = require('tests.support.effect_helpers')

local function update_cell(cell, fn)
  return cell:read_op():and_then(Op.guard(function(old)
    local new = fn(old)
    return cell:write_op(new):map(function()
      return new, old
    end)
  end))
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

-- perform is only legal from a resumed runtime fiber.
do
  local rt = Runtime.new()
  local ok, err = pcall(function()
    return rt:perform(Op.always('x'))
  end)
  assert_error_kind(ok, err, 'phase_error', 'perform outside fiber')
end

-- perform inside guard is rejected because guard runs during search.
do
  local rt = Runtime.new()
  rt:spawn_raw(function()
    rt:perform(Op.guard(function()
      return rt:perform(Op.always('bad'))
    end))
  end):label('guard-performer')
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
  end):label('map-performer')
  local ok, err = pcall(function()
    rt:run()
  end)
  assert_error_kind(ok, err, 'phase_error', 'perform inside map')
end

-- perform inside a guard used for dynamic sequencing is rejected because the guard extends the same candidate world.
do
  local rt = Runtime.new()
  rt:spawn_raw(function()
    rt:perform(Op.always('x'):and_then(Op.guard(function(v)
      rt:perform(Op.always('bad'))
      return Op.always(v)
    end)))
  end):label('guarded-sequencing-performer')
  local ok, err = pcall(function()
    rt:run()
  end)
  assert_error_kind(ok, err, 'phase_error', 'perform inside sequencing guard')
end

-- Spawn is allowed from external driver code and from a resumed fiber, but not
-- from runtime internals.
do
  local rt = Runtime.new()
  local child_ran = false
  rt:spawn_raw(function()
    rt:spawn_raw(function()
      child_ran = true
    end):label('spawned-from-fiber-child')
  end):label('spawned-from-fiber-parent')
  rt:run()
  assert_eq(child_ran, true, 'spawn from resumed fiber is allowed')
end

-- spawn inside guard is rejected because guard is runtime search work, not external code.
do
  local rt = Runtime.new()
  rt:spawn_raw(function()
    rt:perform(Op.guard(function()
      rt:spawn_raw(function() end):label('bad-spawn')
      return Op.always('x')
    end))
  end):label('guard-spawner')
  local ok, err = pcall(function()
    rt:run()
  end)
  assert_error_kind(ok, err, 'phase_error', 'spawn inside guard')
  local ok_spawn = pcall(function()
    rt:spawn_raw(function() end):label('external-spawn-after-guard-error')
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
  end):label('effect-performer')
  local ok, err = pcall(function()
    rt:run()
  end)
  assert_error_kind(ok, err, 'effect_error', 'perform inside effect handler is fatal effect failure')
  assert_eq(err.committed, true, 'effect failure records that commit already happened')
  assert_eq(err.fatal, true, 'effect failure is fatal')
  assert_eq(rt:failed(), err, 'runtime stores fatal effect error')
  assert_eq(rt._phase, 'external', 'effect phase restored after handler error')
  local ok_spawn, spawn_err = pcall(function()
    rt:spawn_raw(function() end):label('after-fatal')
  end)
  assert_error_kind(
    ok_spawn,
    spawn_err,
    'effect_error',
    'failed runtime rejects later spawn with fatal error'
  )
end

-- wrap runs in the resumed fiber and may perform a fresh post-commit transaction.
do
  local rt = Runtime.new()
  local got
  rt:spawn_raw(function()
    got = rt:perform(Op.always('x'):wrap(function(v)
      return v .. rt:perform(Op.always('y'))
    end))
  end):label('wrap-performer')
  local st = rt:run()
  assert_eq(st.tag, 'found', 'wrap perform run status')
  assert_eq(got, 'xy', 'wrap may perform')
end

-- step and run are external driver calls, not fiber calls.
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
  end):label('driver-guard')
  rt:run()
  assert_error_kind(step_ok, step_err, 'phase_error', 'step inside fiber')
  assert_error_kind(run_ok, run_err, 'phase_error', 'run inside fiber')
end

-- A wrap failure happens after commit and must not roll back committed resources.
do
  local cell = Cell.new(0):label('wrap-error-cell')
  local rt = Runtime.new()
  rt:spawn_raw(function()
    rt:perform(cell:write_op(1):wrap(function()
      error('wrap exploded')
    end))
  end):label('wrap-error')
  local ok, _err = pcall(function()
    rt:run()
  end)
  assert_eq(ok, false, 'wrap error should escape the driver by default')
  assert_eq(cell.value, 1, 'wrap error does not roll back commit')
end

-- A raw error inside guard should not leave the runtime believing that an
-- external caller is still inside driver internals.
do
  local rt = Runtime.new()
  rt:spawn_raw(function()
    rt:perform(Op.guard(function()
      error('boom')
    end))
  end):label('guard-raw-error')
  local ok, err = pcall(function()
    rt:run()
  end)
  assert_error_kind(ok, err, 'callback_error', 'raw guard error is structured')
  local ok_spawn = pcall(function()
    rt:spawn_raw(function() end):label('external-after-raw-guard-error')
  end)
  assert_eq(ok_spawn, true, 'external spawn is not blocked after raw guard error')
end

-- Raw map callback errors are also reported as callback errors without
-- poisoning later external calls.
do
  local rt = Runtime.new()
  rt:spawn_raw(function()
    rt:perform(Op.always('x'):map(function()
      error('map boom')
    end))
  end):label('map-raw-error')
  local ok, err = pcall(function()
    rt:run()
  end)
  assert_error_kind(ok, err, 'callback_error', 'raw map error is structured')
  local ok_spawn = pcall(function()
    rt:spawn_raw(function() end):label('external-after-raw-map-error')
  end)
  assert_eq(ok_spawn, true, 'external spawn is not blocked after raw map error')
end

-- A raw effect handler error is also fatal and prevents later driver use.
do
  local cell = Cell.new(0):label('fatal-effect-cell')
  local rt = Runtime.new()
  rt:spawn_raw(function()
    rt:perform(Op.emit(TC.discharge_fatal()):and_then(cell:write_op(1)))
  end):label('raw-effect-error')
  local ok, err = pcall(function()
    rt:run()
  end)
  assert_error_kind(ok, err, 'effect_error', 'raw effect error is fatal')
  assert_eq(err.committed, true, 'raw effect error is after commit')
  assert_eq(err.fatal, true, 'raw effect error marks runtime fatal')
  assert_eq(cell.value, 1, 'raw effect error does not roll back committed resource')
  local ok_run, run_err = pcall(function()
    rt:run()
  end)
  assert_error_kind(ok_run, run_err, 'effect_error', 'failed runtime rejects later run')
end

-- An uncaught phase error from a fiber must not leave later external calls
-- misclassified as runtime-internal calls.
do
  local rt = Runtime.new()
  rt:spawn_raw(function()
    rt:run()
  end):label('fiber-calls-run')
  local ok, err = pcall(function()
    rt:run()
  end)
  assert_error_kind(ok, err, 'phase_error', 'run inside fiber escapes as phase error')
  assert_eq(rt._phase, 'external', 'phase restored after fiber phase error')
  local ok_spawn = pcall(function()
    rt:spawn_raw(function() end):label('external-after-fiber-phase-error')
  end)
  assert_eq(ok_spawn, true, 'external spawn after fiber phase error is allowed')
end

-- Cell updates expressed as algebra protect user callback errors
-- callback errors rather than trusted resource-protocol failures.
do
  local cell = Cell.new(0):label('derived-update-error-cell')
  local rt = Runtime.new()
  rt:spawn_raw(function()
    rt:perform(update_cell(cell, function()
      error('cell update exploded')
    end))
  end):label('derived-update-error')
  local ok, err = pcall(function()
    rt:run()
  end)
  assert_error_kind(ok, err, 'callback_error', 'derived update error is a protected callback error')
  assert_eq(rt._phase, 'external', 'phase restored after derived callback error')
end

print('tests/test_contracts.lua: ok')

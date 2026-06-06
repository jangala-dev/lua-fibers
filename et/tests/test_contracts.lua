-- Runtime host, phase and error contract tests.
package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

local Op = require('et.op')
local Runtime = require('et.runtime')
local Cell = require('et.resources.cell')

local function fail(msg) error(msg, 2) end
local function assert_eq(a, b, msg)
  if a ~= b then fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a)) end
end
local function assert_truthy(v, msg) if not v then fail(msg or 'expected truthy') end end
local function assert_error_kind(ok, err, kind, msg)
  if ok then fail((msg or 'expected error') .. ': call succeeded') end
  if type(err) ~= 'table' or err.kind ~= kind then
    fail((msg or 'wrong error kind') .. ': expected ' .. tostring(kind) .. ', got ' .. tostring(type(err) == 'table' and err.kind or err))
  end
end

-- rt:now uses the injected host clock.
do
  local clock = 12.5
  local rt = Runtime.new({ host = { now = function() return clock end } })
  assert_eq(rt:now(), 12.5, 'initial host clock')
  clock = 99
  assert_eq(rt:now(), 99, 'updated host clock')
end


-- Phase helper preserves arbitrary arity, including nils, without result packing.
do
  local rt = Runtime.new()
  local a, b, c, d, e, f = rt:_enter_phase('contract-test-phase', function(x)
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
  local ok, err = pcall(function() return rt:perform(Op.always('x')) end)
  assert_error_kind(ok, err, 'phase_error', 'perform outside fibre')
end

-- perform inside guard is rejected because guard runs during search.
do
  local rt = Runtime.new()
  rt:spawn(function()
    rt:perform(Op.guard(function()
      return rt:perform(Op.always('bad'))
    end))
  end, 'guard-performer')
  local ok, err = pcall(function() rt:run() end)
  assert_error_kind(ok, err, 'phase_error', 'perform inside guard')
end

-- perform inside map is rejected because map runs during candidate evaluation.
do
  local rt = Runtime.new()
  rt:spawn(function()
    rt:perform(Op.always('x'):map(function(v)
      return v .. rt:perform(Op.always('bad'))
    end))
  end, 'map-performer')
  local ok, err = pcall(function() rt:run() end)
  assert_error_kind(ok, err, 'phase_error', 'perform inside map')
end

-- perform inside and_then is rejected because and_then extends the same candidate world.
do
  local rt = Runtime.new()
  rt:spawn(function()
    rt:perform(Op.always('x'):and_then(function(v)
      rt:perform(Op.always('bad'))
      return Op.always(v)
    end))
  end, 'bind-performer')
  local ok, err = pcall(function() rt:run() end)
  assert_error_kind(ok, err, 'phase_error', 'perform inside and_then')
end

-- perform inside a consequence handler is rejected; consequences are commit-time runtime work.
do
  local rt
  rt = Runtime.new({
    on_consequence = function()
      rt:perform(Op.always('bad'))
    end,
  })
  rt:spawn(function() rt:perform(Op.emit({ kind = 'contract-test' })) end, 'consequence-performer')
  local ok, err = pcall(function() rt:run() end)
  assert_error_kind(ok, err, 'phase_error', 'perform inside consequence handler')
  assert_eq(rt._phase, 'external', 'consequence phase restored after handler error')
end

-- wrap runs in the resumed fibre and may perform a fresh post-commit transaction.
do
  local rt = Runtime.new()
  local got
  rt:spawn(function()
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
  rt:spawn(function()
    step_ok, step_err = pcall(function() return rt:step() end)
    run_ok, run_err = pcall(function() return rt:run() end)
  end, 'driver-guard')
  rt:run()
  assert_error_kind(step_ok, step_err, 'phase_error', 'step inside fibre')
  assert_error_kind(run_ok, run_err, 'phase_error', 'run inside fibre')
end

-- A wrap failure happens after commit and must not roll back committed resources.
do
  local cell = Cell.new(0, 'wrap-error-cell')
  local rt = Runtime.new()
  rt:spawn(function()
    rt:perform(cell:set_op(Op, 1):wrap(function()
      error('wrap exploded')
    end))
  end, 'wrap-error')
  local ok, _err = pcall(function() rt:run() end)
  assert_eq(ok, false, 'wrap error should escape the driver by default')
  assert_eq(cell.value, 1, 'wrap error does not roll back commit')
end

print('tests/test_contracts.lua: ok')

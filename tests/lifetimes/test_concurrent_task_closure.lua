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
local FibersSignal = require('fibers.resource.signal')

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

-- Normal body return waits for all successful Task roots held in custody before the
-- root lifetime is considered honest.
do
  local a_done, b_done = false, false
  local r = fibers.try_run(function()
    fibers.spawn(function()
      a_done = true
    end):label('settle-success-a')
    fibers.spawn(function()
      b_done = true
    end):label('settle-success-b')
    return 'body-ok'
  end)
  assert_truthy(r.ok, 'successful children should settle successfully')
  assert_eq(r:unpack(), 'body-ok')
  assert_truthy(a_done and b_done, 'scope should wait for successful root tasks')
end

-- A child failure after the root body returns is still the root lifetime's
-- failure. This is the fire-and-account property: Tasks held in custody cannot fail
-- silently after their creating function returns.
do
  local r = fibers.try_run(function()
    fibers.spawn(function()
      error('late child boom', 0)
    end):label('late-failing-child')
    return 'body-ok'
  end)
  assert_eq(r.ok, false)
  assert_eq(r.reason, 'child_failed')
  assert_truthy(
    tostring(r.primary):match('late child boom') or tostring(r.report):match('late child boom'),
    'late child failure should be reported'
  )
end

-- Closure observes task exits concurrently. A pending sibling must not hide a
-- failing sibling that exits first; Closure propagation should notice the failure, cancel
-- the pending sibling, and then retire both through normal closure.
do
  local waiter
  local r = fibers.try_run(function()
    local src = FibersSignal.new():label('concurrent-closure-never')
    waiter = fibers.spawn(function()
      fibers.perform(src:wait_op())
    end):label('pending-sibling')

    fibers.spawn(function()
      error('sibling boom', 0)
    end):label('failing-sibling')

    return 'body-ok'
  end)

  assert_eq(r.ok, false)
  assert_eq(r.reason, 'child_failed')
  assert_truthy(
    tostring(r.primary):match('sibling boom') or tostring(r.report):match('sibling boom'),
    'failing sibling should be reported'
  )

  local waiter_exit
  fibers.run(function()
    waiter_exit = fibers.perform(waiter:body_result_op())
  end)
  assert_truthy(
    waiter_exit.tag == 'cancelled' or waiter_exit.tag == 'failed',
    'pending sibling should not remain pending'
  )
end

print('tests/test_concurrent_task_closure.lua: ok')

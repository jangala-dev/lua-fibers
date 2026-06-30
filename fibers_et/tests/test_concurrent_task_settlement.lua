package.path = table.concat({'./?.lua','./?/init.lua','./?/?.lua',package.path}, ';')

local fibers = require('fibers')

local function fail(msg) error(msg, 2) end
local function assert_eq(a, b, msg) if a ~= b then fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a)) end end
local function assert_truthy(v, msg) if not v then fail(msg or 'expected truthy') end end

-- Normal body return waits for all successful owned task roots before the
-- root lifetime is considered honest.
do
  local a_done, b_done = false, false
  local r = fibers.try_run(function()
    fibers.spawn(function() a_done = true end, 'settle-success-a')
    fibers.spawn(function() b_done = true end, 'settle-success-b')
    return 'body-ok'
  end)
  assert_truthy(r.ok, 'successful children should settle successfully')
  assert_eq(r:unpack(), 'body-ok')
  assert_truthy(a_done and b_done, 'scope should wait for successful root tasks')
end

-- A child failure after the root body returns is still the root lifetime's
-- failure. This is the fire-and-account property: owned tasks cannot fail
-- silently after their creating function returns.
do
  local r = fibers.try_run(function()
    fibers.spawn(function()
      error('late child boom', 0)
    end, 'late-failing-child')
    return 'body-ok'
  end)
  assert_eq(r.ok, false)
  assert_eq(r.reason, 'child_failed')
  assert_truthy(tostring(r.primary):match('late child boom') or tostring(r.report):match('late child boom'), 'late child failure should be reported')
end

-- Settlement observes task exits concurrently. A pending sibling must not hide a
-- failing sibling that exits first; the policy should notice the failure, cancel
-- the pending sibling, and then retire both through normal settlement.
do
  local waiter
  local r = fibers.try_run(function()
    local src = fibers.Source.signal('concurrent-settlement-never')
    waiter = fibers.spawn(function()
      fibers.perform(src:wait_op())
    end, 'pending-sibling')

    fibers.spawn(function()
      error('sibling boom', 0)
    end, 'failing-sibling')

    return 'body-ok'
  end)

  assert_eq(r.ok, false)
  assert_eq(r.reason, 'child_failed')
  assert_truthy(tostring(r.primary):match('sibling boom') or tostring(r.report):match('sibling boom'), 'failing sibling should be reported')

  local waiter_state
  fibers.run(function()
    waiter_state = fibers.perform(waiter:state_op())
  end)
  assert_truthy(waiter_state and waiter_state.exited, 'pending sibling should be cancelled and settled')
  assert_truthy(waiter_state.exit.tag == 'cancelled' or waiter_state.exit.tag == 'failed', 'pending sibling should not remain pending')
end

print('tests/test_concurrent_task_settlement.lua: ok')

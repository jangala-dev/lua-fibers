package.path = table.concat({'./?.lua','./?/init.lua','./?/?.lua',package.path}, ';')

local fibers = require('fibers')

local function fail(msg) error(msg, 2) end
local function assert_eq(a, b, msg) if a ~= b then fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a)) end end
local function assert_truthy(v, msg) if not v then fail(msg or 'expected truthy') end end
local function assert_status(st, tag, msg) if not st or st.tag ~= tag then fail((msg or 'status mismatch') .. ': expected ' .. tostring(tag) .. ', got ' .. tostring(st and st.tag)) end end

-- The friendly spawn name uses the current root scope installed by fibers.run.
do
  local child
  local st = fibers.try_run(function()
    child = fibers.spawn(function() return 'ok' end)
    local exit = fibers.perform(child:exit_op())
    assert_eq(exit.tag, 'returned')
  end).runtime_status
  assert_truthy(st.tag == 'found' or st.tag == 'pending' or st.tag == 'idle', 'unexpected status: ' .. tostring(st.tag))
  assert_truthy(child, 'fibers.spawn should return a task handle under the root scope')
end

-- Nursery launch installs the policy once; ordinary perform/spawn are pleasant
-- inside the boundary.
do
  local got, child
  local st = fibers.launch(fibers.policy.nursery(), function(n)
    local ch = fibers.Rendezvous.new('policy-rendezvous')
    child = fibers.spawn(function()
      fibers.perform(ch:put_op('hello'))
    end, 'sender')
    got = fibers.perform(ch:get_op())
  end)
  assert_truthy(st.tag == 'found' or st.tag == 'pending' or st.tag == 'idle', 'unexpected status: ' .. tostring(st.tag))
  assert_eq(got, 'hello')
  assert_truthy(child, 'nursery spawn should return a task handle')
end

-- Direct cancellation is task-level. Scope policy uses the same task/resource
-- protocols internally during settlement.
do
  local task
  local st = fibers.launch(fibers.policy.nursery(), function(n)
    local src = fibers.Source.signal('policy-cancel-source')
    task = fibers.spawn(function()
      fibers.perform(src:wait_op())
    end, 'waiter')
    fibers.perform(task:request_cancel_op('stop'))
    local exit = fibers.perform(task:exit_op())
    assert_truthy(exit.tag == 'cancelled' or exit.tag == 'failed', 'explicit cancellation should end the task')
  end)
  assert_truthy(st.tag == 'found' or st.tag == 'pending' or st.tag == 'idle', 'unexpected status: ' .. tostring(st.tag))
end

-- Body failure cancels owned children before the nursery reports the body error.
do
  local child
  local ok, err = pcall(function()
    fibers.launch(fibers.policy.nursery(), function()
      local src = fibers.Source.signal('policy-body-failure-source')
      child = fibers.spawn(function()
        fibers.perform(src:wait_op())
      end, 'owned-waiter')
      error('body failed')
    end)
  end)
  assert_eq(ok, false)
  assert_truthy(tostring(err):match('body failed'))
  local state
  local st = fibers.try_run(function() state = fibers.perform(child:state_op()) end).runtime_status
  assert_truthy(st.tag == 'found' or st.tag == 'pending' or st.tag == 'idle', 'unexpected status: ' .. tostring(st.tag))
  assert_truthy(state.exit.tag == 'cancelled' or state.exit.tag == 'failed', 'child should be cancelled or report scope failure under body failure')
end

print('tests/test_policy.lua: ok')

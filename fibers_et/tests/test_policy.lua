package.path = table.concat({'./?.lua','./?/init.lua','./?/?.lua',package.path}, ';')

local fibers = require('fibers')

local function fail(msg) error(msg, 2) end
local function assert_eq(a, b, msg) if a ~= b then fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a)) end end
local function assert_truthy(v, msg) if not v then fail(msg or 'expected truthy') end end
local function assert_status(st, tag, msg) if not st or st.tag ~= tag then fail((msg or 'status mismatch') .. ': expected ' .. tostring(tag) .. ', got ' .. tostring(st and st.tag)) end end

-- The friendly spawn name is policy-aware, not raw.  Raw fibres remain explicit.
do
  local saw_error = false
  fibers.run(function()
    local ok = pcall(function() fibers.spawn(function() end) end)
    saw_error = not ok
  end)
  assert_truthy(saw_error, 'fibers.spawn should require a launch policy')
end

-- Nursery launch installs the policy once; ordinary perform/spawn are pleasant
-- inside the boundary.
do
  local got, child
  local st = fibers.launch(fibers.policy.nursery(), function()
    local ch = fibers.Channel.new('policy-channel')
    child = fibers.spawn(function()
      fibers.perform(ch:send_op('hello'))
    end, 'sender')
    got = fibers.perform(ch:recv_op())
  end)
  assert_status(st, 'found')
  assert_eq(got, 'hello')
  assert_truthy(child and child._fibers_obligation_kind == 'task')
  assert_eq(child.owner, nil, 'nursery should settle completed owned children on exit')
end

-- Region cancellation is authority-oriented and interrupts a task perform at the
-- boundary; the user operation is not rewritten as a choice.
do
  local task
  local st = fibers.launch(fibers.policy.nursery(), function(n)
    local src = fibers.Source.manual('policy-cancel-source')
    task = fibers.spawn(function()
      fibers.perform(src:next_op())
    end, 'waiter')
    fibers.perform(n.region:cancel_op(task, 'stop'))
    local status, reason = fibers.perform(task:join_op())
    assert_eq(status, 'cancelled')
    assert_eq(reason, 'stop')
  end)
  assert_status(st, 'found')
  assert_eq(task.completion.value.status, 'cancelled')
end

-- Body failure cancels owned children before the nursery reports the body error.
do
  local child
  local ok, err = pcall(function()
    fibers.launch(fibers.policy.nursery(), function()
      local src = fibers.Source.manual('policy-body-failure-source')
      child = fibers.spawn(function()
        fibers.perform(src:next_op())
      end, 'owned-waiter')
      error('body failed')
    end)
  end)
  assert_eq(ok, false)
  assert_truthy(tostring(err):match('body failed'))
  assert_eq(child.completion.value.status, 'cancelled')
end

print('tests/test_policy.lua: ok')

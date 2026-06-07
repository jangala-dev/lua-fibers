package.path = table.concat({'./?.lua','./?/init.lua','./?/?.lua',package.path}, ';')

local fibers = require('fibers')

local function fail(msg) error(msg, 2) end
local function assert_eq(a, b, msg) if a ~= b then fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a)) end end
local function assert_truthy(v, msg) if not v then fail(msg or 'expected truthy') end end
local function assert_status(st, tag, msg) if not st or st.tag ~= tag then fail((msg or 'status mismatch') .. ': expected ' .. tostring(tag) .. ', got ' .. tostring(st and st.tag)) end end

-- The friendly top-level surface is enough for ordinary channel use.
do
  local ch = fibers.Channel.new('inbox')
  local got
  local st = fibers.run(function()
    fibers.spawn(function()
      fibers.perform(ch:send_op('hello'))
    end, 'sender')
    got = fibers.perform(ch:recv_op())
  end)
  assert_status(st, 'found')
  assert_eq(got, 'hello')
end

-- Cells provide transactional facts; wait_op resumes when a committed change
-- makes the predicate true.
do
  local cell = fibers.Cell.new(false, 'flag')
  local seen
  local st = fibers.run(function()
    fibers.spawn(function()
      seen = fibers.perform(cell:wait_op(function(v) return v == true end))
    end, 'waiter')
    fibers.perform(cell:set_op(true))
  end)
  assert_status(st, 'found')
  assert_eq(seen, true)
end

-- modify_when_op is the small reusable shape behind capacity-like resources.
do
  local c = fibers.Cell.new(1, 'credits')
  local new, old
  local st = fibers.run(function()
    new, old = fibers.perform(c:modify_when_op(
      function(v) return v > 0 end,
      function(v) return v - 1 end
    ))
  end)
  assert_status(st, 'found')
  assert_eq(old, 1)
  assert_eq(new, 0)
  assert_eq(c.value, 0)
end

-- A Source is a public waitable external occurrence.
do
  local src = fibers.Source.manual('signal')
  local rt = fibers.Runtime.new()
  local got
  rt:spawn(function()
    got = rt:perform(src:next_op())
  end, 'source-waiter')
  local st = rt:run()
  assert_status(st, 'pending')
  local waits = rt:pending_wait_summary()
  assert_eq(waits[1].kind, 'source')
  src:emit('ready')
  st = rt:step()
  assert_status(st, 'found')
  assert_eq(got, 'ready')
end

-- Clock sources are ordinary Sources backed by host time.
do
  local now = 0
  local clock = fibers.Source.clock('test-clock')
  local rt = fibers.Runtime.new({ host = { now = function() return now end } })
  local ok, observed
  rt:spawn(function()
    ok, observed = rt:perform(clock:after_op(5))
  end, 'sleeper')
  local st = rt:run()
  assert_status(st, 'pending')
  now = 5
  st = rt:step()
  assert_status(st, 'found')
  assert_eq(ok, true)
  assert_eq(observed, 5)
end

-- Effects are the public form of typed transaction consequences.
do
  local published = 0
  local Kind = fibers.Effect.kind {
    name = 'test-effect',
    key = function(payload) return payload.key end,
    merge = function(a, _b) return a end,
    prepare = function(_rt, payload)
      return {
        kind = Kind,
        key = payload.key,
        payload = payload,
        publish = function()
          published = published + 1
        end,
      }
    end,
  }
  local effect = fibers.Effect.of(Kind, { key = 'once' })
  local st = fibers.run(function()
    fibers.perform(fibers.after_commit(effect))
  end)
  assert_status(st, 'found')
  assert_eq(published, 1)
end

-- Region and Task make post-commit spawn usable directly.
do
  local region = fibers.Region.new('root-region')
  local status, value, task
  local st = fibers.run(function()
    task = fibers.perform(region:spawn_op(function()
      return 7
    end, 'child'))
    status, value = fibers.perform(task:join_op())
  end)
  assert_status(st, 'found')
  assert_truthy(task, 'spawn should return a task handle')
  assert_eq(task.owner, region)
  assert_eq(status, 'ok')
  assert_eq(value, 7)
end


-- The public base-kit pieces compose in one ordinary programme.
do
  local inbox = fibers.Channel.new('base-kit-inbox')
  local flag = fibers.Cell.new(false, 'base-kit-flag')
  local region = fibers.Region.new('base-kit-region')
  local received, joined

  local st = fibers.run(function()
    fibers.spawn(function()
      fibers.perform(inbox:send_op('hello'))
      fibers.perform(flag:set_op(true))
    end, 'sender')

    local task = fibers.perform(region:spawn_op(function()
      local value = fibers.perform(flag:wait_op(function(v) return v == true end))
      return value and 42 or 0
    end, 'worker'))

    received = fibers.perform(fibers.choice(
      inbox:recv_op(),
      fibers.clock:after_op(1):map(function() return 'timeout' end)
    ))

    local status, value = fibers.perform(task:join_op())
    joined = { status = status, value = value }
  end)

  assert_status(st, 'found')
  assert_eq(received, 'hello')
  assert_eq(joined.status, 'ok')
  assert_eq(joined.value, 42)
end

print('tests/test_base_kit.lua: ok')

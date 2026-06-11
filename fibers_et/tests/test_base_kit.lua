package.path = table.concat({'./?.lua','./?/init.lua','./?/?.lua',package.path}, ';')

local fibers = require('fibers')

local function fail(msg) error(msg, 2) end
local function assert_eq(a, b, msg) if a ~= b then fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a)) end end
local function assert_truthy(v, msg) if not v then fail(msg or 'expected truthy') end end
local function assert_status(st, tag, msg) if not st or st.tag ~= tag then fail((msg or 'status mismatch') .. ': expected ' .. tostring(tag) .. ', got ' .. tostring(st and st.tag)) end end

local function wait_until(cell, pred)
  local function loop()
    return cell:snapshot_op():and_then(function(s)
      if pred(s.value) then return fibers.always(s.value) end
      return cell:changed_op(s.version):and_then(function() return loop() end)
    end)
  end
  return loop()
end

local function modify_when(cell, pred, update)
  local function loop()
    return cell:snapshot_op():and_then(function(s)
      if not pred(s.value) then
        return cell:changed_op(s.version):and_then(function() return loop() end)
      end
      local new = update(s.value)
      return cell:write_op(new):map(function() return new, s.value end)
    end)
  end
  return loop()
end


-- Layer aggregates make the repository structure explicit without changing the
-- ordinary convenience facade.
do
  local base = require('fibers.base')
  local facility = require('fibers.facility')
  local kernel = require('fibers.kernel')
  assert_eq(base.Op, fibers.Op, 'base aggregate exports Op')
  assert_eq(base.Cell, fibers.Cell, 'base aggregate exports Cell')
  assert_eq(base.Channel, fibers.Channel, 'base aggregate exports Channel')
  assert_eq(base.Source, fibers.Source, 'base aggregate exports Source')
  assert_eq(base.Region, fibers.Region, 'base aggregate exports Region')
  assert_eq(base.Task, fibers.Task, 'base aggregate exports Task')
  assert_eq(base.Effect, fibers.Effect, 'base aggregate exports Effect')
  assert_eq(facility.Lifetime, fibers.Lifetime, 'facility aggregate exports Lifetime')
  assert_eq(facility.policy, fibers.policy, 'facility aggregate exports policy')
  assert_eq(kernel.Runtime, fibers.Runtime, 'kernel aggregate exports Runtime')
end

-- The friendly top-level surface is enough for ordinary channel use.
do
  local ch = fibers.Channel.new('inbox')
  local got
  local st = fibers.run(function()
    fibers.spawn_raw(function()
      fibers.perform(ch:put_op('hello'))
    end, 'sender')
    got = fibers.perform(ch:get_op())
  end)
  assert_status(st, 'found')
  assert_eq(got, 'hello')
end

-- Cells provide transactional facts; waiting is expressed with snapshot/changed and Op composition.
do
  local cell = fibers.Cell.new(false, 'flag')
  local seen
  local st = fibers.run(function()
    fibers.spawn_raw(function()
      seen = fibers.perform(wait_until(cell, function(v) return v == true end))
    end, 'waiter')
    fibers.perform(cell:write_op(true))
  end)
  assert_status(st, 'found')
  assert_eq(seen, true)
end

-- Capacity-like state transitions are ordinary algebra over snapshot/changed/set.
do
  local c = fibers.Cell.new(1, 'credits')
  local new, old
  local st = fibers.run(function()
    new, old = fibers.perform(modify_when(c,
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
  local rt = fibers.Runtime.new()
  local src, feed = rt:signal('signal')
  local got
  rt:spawn_raw(function()
    got = rt:perform(src:wait_op())
  end, 'source-waiter')
  local st = rt:run()
  assert_status(st, 'pending')
  local waits = rt:pending_wait_summary()
  assert_eq(waits[1].kind, 'source')
  feed:set('ready')
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
  rt:spawn_raw(function()
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
  local value, task
  local st = fibers.run(function()
    task = fibers.perform(fibers.Task.spawn_op(region, function()
      return 7
    end, 'child'))
    value = fibers.perform(task:await_op())
  end)
  assert_status(st, 'found')
  assert_truthy(task, 'spawn should return a task handle')
  assert_eq(task.owner, region)
  assert_eq(value, 7)
end


-- The public base-kit pieces compose in one ordinary programme.
do
  local inbox = fibers.Channel.new('base-kit-inbox')
  local flag = fibers.Cell.new(false, 'base-kit-flag')
  local region = fibers.Region.new('base-kit-region')
  local received, joined

  local st = fibers.run(function()
    fibers.spawn_raw(function()
      fibers.perform(inbox:put_op('hello'))
      fibers.perform(flag:write_op(true))
    end, 'sender')

    local task = fibers.perform(fibers.Task.spawn_op(region, function()
      local value = fibers.perform(wait_until(flag, function(v) return v == true end))
      return value and 42 or 0
    end, 'worker'))

    received = fibers.perform(fibers.choice(
      inbox:get_op(),
      fibers.clock:after_op(1):map(function() return 'timeout' end)
    ))

    local value = fibers.perform(task:await_op())
    joined = { value = value }
  end)

  assert_status(st, 'found')
  assert_eq(received, 'hello')
  assert_eq(joined.value, 42)
end


-- Task await unwraps Exit and preserves Lua multiple-return values.
do
  local region = fibers.Region.new('multi-return-region')
  local a, b, c, exit
  local st = fibers.run(function()
    local task = fibers.perform(fibers.Task.spawn_op(region, function()
      return 'x', nil, 'z'
    end, 'multi-return-task'))
    exit = fibers.perform(task:exit_op())
    a, b, c = fibers.perform(task:await_op())
  end)
  assert_status(st, 'found')
  assert_eq(exit.tag, 'returned')
  assert_eq(a, 'x')
  assert_eq(b, nil)
  assert_eq(c, 'z')
end

print('tests/test_base_kit.lua: ok')

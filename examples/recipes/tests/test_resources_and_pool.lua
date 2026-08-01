-- Keyed, Lease, PriorityQueue, and Pool facility laws.

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
local Keyed = require('fibers.resource.keyed')
local Lease = require('fibers.resource.lease')
local PriorityQueue = require('examples.recipes.priority_queue')
local Pool = require('examples.recipes.resource_pool')
local Runtime = require('fibers.runtime')

local function fail(msg)
  error(msg, 2)
end
local function assert_eq(a, b, msg)
  if a ~= b then
    fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a))
  end
end
local function assert_nil(v, msg)
  if v ~= nil then
    fail((msg or 'expected nil') .. ': got ' .. tostring(v))
  end
end
local function assert_status(st, tag, msg)
  if not st or st.tag ~= tag then
    fail((msg or 'status mismatch') .. ': expected ' .. tostring(tag) .. ', got ' .. tostring(st and st.tag))
  end
end
local function new_runtime(opts)
  return Runtime.new(opts or {})
end

local function seed_lease(lease, subject, holders)
  local rt = new_runtime()
  local ops = {}
  for holder, mode in pairs(holders) do
    ops[#ops + 1] = lease:acquire_op(subject, mode, holder)
  end
  rt:spawn_raw(function()
    rt:perform(#ops == 1 and ops[1] or Op.each(ops))
  end, 'lease-seed')
  assert_status(rt:run(), 'found', 'lease seed')
end

local function perform_op(op)
  local rt, value = new_runtime()
  rt:spawn_raw(function()
    value = rt:perform(op)
  end, 'probe')
  assert_status(rt:run(), 'found')
  return value
end

local function assert_key(map, key, expected)
  assert_eq(perform_op(map:contains_op(key)), expected ~= nil)
  if expected ~= nil then
    assert_eq(perform_op(map:get_op(key)), expected)
  end
end

local function test_keyed_together_put_supplies_get()
  local rt = new_runtime()
  local m = Keyed.new('keyed-together')
  local rows
  rt:spawn_raw(function()
    rows = rt:perform(Op.together({ m:put_op('k', 'v'), m:get_op('k') }))
  end, 'root')
  assert_status(rt:run(), 'found')
  assert_eq(rows[2][1], 'v')
  assert_key(m, 'k', 'v')
end

local function test_keyed_each_put_does_not_supply_get()
  local rt = new_runtime()
  local m = Keyed.new('keyed-each')
  local rows
  rt:spawn_raw(function()
    rows = rt:perform(Op.each({ m:put_op('k', 'v'), m:get_op('k'):or_else(Op.always('missing')) }))
  end, 'root')
  assert_status(rt:run(), 'found')
  assert_eq(rows[2][1], 'missing')
  assert_key(m, 'k', 'v')
end

local function test_keyed_remove_and_get_share_parent_value()
  local rt = new_runtime()
  local m = Keyed.from({ a = 'A', b = 'B' }, 'keyed-remove-each')
  local rows
  rt:spawn_raw(function()
    rows = rt:perform(Op.each({ m:remove_op('a'), m:get_op('a'):or_else(Op.always('missing')) }))
  end, 'root')
  assert_status(rt:run(), 'found')
  assert_eq(rows[1][1], true)
  assert_eq(rows[2][1], 'A')
  assert_key(m, 'a', nil)
  assert_key(m, 'b', 'B')
end

local function test_keyed_take_returns_value()
  local rt = new_runtime()
  local m = Keyed.from({ a = 'A' }, 'keyed-take')
  local v
  rt:spawn_raw(function()
    v = rt:perform(m:take_op('a'))
  end, 'root')
  assert_status(rt:run(), 'found')
  assert_eq(v, 'A')
  assert_key(m, 'a', nil)
end

local function test_lease_readers_merge_and_writer_conflicts()
  local rt = new_runtime()
  local c = Lease.new({ read = { read = true }, write = {} }, 'lease-rw')
  local rows
  rt:spawn_raw(function()
    rows = rt:perform(Op.each({ c:acquire_op('s', 'read', 'a'), c:acquire_op('s', 'read', 'b') }))
  end, 'root')
  assert_status(rt:run(), 'found')
  assert_eq(rows[1][1], true)
  assert_eq(rows[2][1], true)
  assert_eq(c.holders.s.a, 'read')
  assert_eq(c.holders.s.b, 'read')

  local rt2 = new_runtime({ quiet_deadlock = true })
  rt2:spawn_raw(function()
    rt2:perform(c:acquire_op('s', 'write', 'w'))
  end, 'root')
  local st = rt2:run()
  if st and st.tag == 'found' then
    fail('writer should not acquire while readers hold')
  end
end

local function test_lease_together_release_supplies_acquire_but_each_does_not()
  local c = Lease.new({ read = { read = true }, write = {} }, 'lease-release')
  seed_lease(c, 's', { writer = 'write' })
  local rt = new_runtime()
  local rows
  rt:spawn_raw(function()
    rows = rt:perform(Op.each({
      c:release_op('s', 'writer'),
      c:acquire_op('s', 'read', 'reader'):or_else(Op.always('blocked')),
    }))
  end, 'root')
  assert_status(rt:run(), 'found')
  assert_eq(rows[2][1], 'blocked')
  assert_nil((c.holders.s or {}).writer)

  seed_lease(c, 's', { writer = 'write' })
  local rt2 = new_runtime()
  local rows2
  rt2:spawn_raw(function()
    rows2 = rt2:perform(Op.together({ c:release_op('s', 'writer'), c:acquire_op('s', 'read', 'reader') }))
  end, 'root')
  assert_status(rt2:run(), 'found')
  assert_eq(rows2[2][1], true)
  assert_eq(c.holders.s.reader, 'read')
end

local function test_priority_queue_order_and_handoff_laws()
  local rt = new_runtime()
  local pq = PriorityQueue.new(math.huge, 'pq-order')
  rt:spawn_raw(function()
    rt:perform(Op.each({ pq:put_op(10, 'low'), pq:put_op(1, 'high') }))
  end, 'seed')
  assert_status(rt:run(), 'found')
  local rt2 = new_runtime()
  local v, priority
  rt2:spawn_raw(function()
    v, priority = rt2:perform(pq:get_op())
  end, 'root')
  assert_status(rt2:run(), 'found')
  assert_eq(v, 'high')
  assert_eq(priority, 1)

  local pq2 = PriorityQueue.new(math.huge, 'pq-law')
  local rt3 = new_runtime()
  local rows
  rt3:spawn_raw(function()
    rows = rt3:perform(Op.together({ pq2:put_op(0, 'urgent'), pq2:get_op() }))
  end, 'root')
  assert_status(rt3:run(), 'found')
  assert_eq(rows[2][1], 'urgent')
  local empty
  local rt_empty = new_runtime()
  rt_empty:spawn_raw(function()
    empty = rt_empty:perform(pq2:get_op():or_else(Op.always('empty')))
  end, 'empty-check')
  assert_status(rt_empty:run(), 'found')
  assert_eq(empty, 'empty')

  local pq3 = PriorityQueue.new(math.huge, 'pq-each')
  local rt4 = new_runtime()
  local rows4
  rt4:spawn_raw(function()
    rows4 = rt4:perform(Op.each({ pq3:put_op(0, 'urgent'), pq3:get_op():or_else(Op.always('empty')) }))
  end, 'root')
  assert_status(rt4:run(), 'found')
  assert_eq(rows4[2][1], 'empty')
end

local function test_pool_acquire_release_and_retirement()
  local retired = {}
  local pool = Pool.new({
    name = 'pool-basic',
    retire = function(item, reason, key)
      retired[#retired + 1] = { item = item, reason = reason, key = key }
    end,
  })
  local rt = new_runtime()
  local lease
  rt:spawn_raw(function()
    lease = rt:perform(pool:add_op('a', 'A'):and_then(pool:acquire_op('u1')))
  end, 'root')
  assert_status(rt:run(), 'found')
  assert_eq(lease.key, 'a')
  assert_eq(lease.item, 'A')
  assert_eq((pool.leases.holders.a or {}).u1, 'lease')

  local rt2 = new_runtime()
  rt2:spawn_raw(function()
    rt2:perform(pool:release_op(lease))
  end, 'root')
  assert_status(rt2:run(), 'found')
  assert_nil((pool.leases.holders.a or {}).u1)
  assert_eq(perform_op(pool.items:get_op('a')).item, 'A')
  assert_eq(pool.idle.entries.a.value, 'a')

  local rt3 = new_runtime()
  rt3:spawn_raw(function()
    rt3:perform(pool:retire_op('a', 'bad'))
  end, 'root')
  assert_status(rt3:run(), 'found')
  assert_eq(perform_op(pool.items:contains_op('a')), false)
  assert_eq(#retired, 1)
  assert_eq(retired[1].item, 'A')
end

local function test_pool_each_add_does_not_supply_acquire_but_together_does()
  local pool = Pool.new({ name = 'pool-law' })
  local rt = new_runtime()
  local rows
  rt:spawn_raw(function()
    rows = rt:perform(Op.each({ pool:add_op('x', 'X'), pool:acquire_op('u'):or_else(Op.always('empty')) }))
  end, 'root')
  assert_status(rt:run(), 'found')
  assert_eq(rows[2][1], 'empty')
  assert_eq(perform_op(pool.items:get_op('x')).item, 'X')
  assert_eq(pool.idle.entries.x.value, 'x')

  local pool2 = Pool.new({ name = 'pool-together' })
  local rt2 = new_runtime()
  local rows2
  rt2:spawn_raw(function()
    rows2 = rt2:perform(Op.together({ pool2:add_op('x', 'X'), pool2:acquire_op('u') }))
  end, 'root')
  assert_status(rt2:run(), 'found')
  assert_eq(rows2[2][1].item, 'X')
  assert_eq(perform_op(pool2.items:get_op('x')).item, 'X')
  assert_eq(pool2.idle.entries.x, nil)
  assert_eq(pool2.leases.holders.x.u, 'lease')
end

local function test_pool_retire_leased_defers_until_release()
  local retired = {}
  local pool = Pool.new({
    name = 'pool-defer',
    retire = function(item, reason, key)
      retired[#retired + 1] = { item = item, reason = reason, key = key }
    end,
  })
  local lease
  local rt = new_runtime()
  rt:spawn_raw(function()
    lease = rt:perform(pool:add_op('a', 'A'):and_then(pool:acquire_op('u')))
  end, 'seed')
  assert_status(rt:run(), 'found')
  local rt2 = new_runtime()
  rt2:spawn_raw(function()
    rt2:perform(pool:retire_op('a', 'old'))
  end, 'retire')
  assert_status(rt2:run(), 'found')
  assert_eq(#retired, 0)
  assert_eq(perform_op(pool.items:get_op('a')).retire_on_release, true)
  local rt3 = new_runtime()
  rt3:spawn_raw(function()
    rt3:perform(pool:release_op(lease))
  end, 'release')
  assert_status(rt3:run(), 'found')
  assert_eq(#retired, 1)
  assert_eq(perform_op(pool.items:contains_op('a')), false)
end

local function test_keyed_take_then_put_replaces()
  local rt = new_runtime()
  local m = Keyed.from({ a = 'A' }, 'keyed-replace-after-remove-present')
  local old
  rt:spawn_raw(function()
    old = rt:perform(m:take_op('a'):and_then(Op.guard(function(v)
      return m:put_op('a', 'A2'):map(function()
        return v
      end)
    end)))
  end, 'root')
  assert_status(rt:run(), 'found')
  assert_eq(old, 'A')
  assert_key(m, 'a', 'A2')
end

local function test_pool_close_constrains_acquire_under_together_and_each()
  local pool = Pool.new({ name = 'pool-close-law' })
  local rt = new_runtime()
  local rows
  rt:spawn_raw(function()
    rows = rt:perform(pool:add_op('a', 'A'):and_then(Op.together({
      pool:close_op('shutdown'),
      pool:acquire_op('u'):or_else(Op.always('closed')),
    })))
  end, 'root')
  assert_status(rt:run(), 'found')
  assert_eq(rows[2][1], 'closed')
  assert_eq(pool.open.value, false)
  assert_eq(perform_op(pool.items:get_op('a')).item, 'A')
  assert_eq(pool.idle.entries.a.value, 'a')

  local pool2 = Pool.new({ name = 'pool-close-law-each' })
  local rt2 = new_runtime()
  local rows2
  rt2:spawn_raw(function()
    rows2 = rt2:perform(pool2:add_op('a', 'A'):and_then(Op.each({
      pool2:close_op('shutdown'),
      pool2:acquire_op('u'):or_else(Op.always('closed')),
    })))
  end, 'root')
  assert_status(rt2:run(), 'found')
  assert_eq(rows2[2][1], 'closed')
  assert_eq(pool2.open.value, false)
  assert_eq(perform_op(pool2.items:get_op('a')).item, 'A')
  assert_eq(pool2.idle.entries.a.value, 'a')
end

local tests = {
  test_keyed_together_put_supplies_get,
  test_keyed_each_put_does_not_supply_get,
  test_keyed_remove_and_get_share_parent_value,
  test_keyed_take_returns_value,
  test_keyed_take_then_put_replaces,
  test_lease_readers_merge_and_writer_conflicts,
  test_lease_together_release_supplies_acquire_but_each_does_not,
  test_priority_queue_order_and_handoff_laws,
  test_pool_acquire_release_and_retirement,
  test_pool_each_add_does_not_supply_acquire_but_together_does,
  test_pool_retire_leased_defers_until_release,
  test_pool_close_constrains_acquire_under_together_and_each,
}

for i = 1, #tests do
  tests[i]()
end

print('examples/recipes/tests/test_resources_and_pool.lua: ok')

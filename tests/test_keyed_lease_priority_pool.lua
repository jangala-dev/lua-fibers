-- Keyed, Lease, PriorityQueue, and Pool facility laws.

package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './reference/?.lua',
  './reference/?/init.lua',
  './reference/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

local Op = require('fibers.atoms.op')
local Keyed = require('fibers.atoms.keyed')
local Lease = require('fibers.atoms.lease')
local PriorityQueue = require('fibers.priority_queue')
local Pool = require('fibers.pool')
local Runtime = require('fibers.kernel.runtime')

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
    fail(
      (msg or 'status mismatch')
        .. ': expected '
        .. tostring(tag)
        .. ', got '
        .. tostring(st and st.tag)
    )
  end
end
local function new_runtime(opts)
  return Runtime.new(opts or {})
end

local function test_keyed_tensor_put_supplies_get()
  local rt = new_runtime()
  local m = Keyed.new({}, 'keyed-tensor')
  local rows
  rt:spawn_raw(function()
    rows = rt:perform(Op.tensor({ m:put_op('k', 'v'), m:get_op('k') }))
  end, 'root')
  assert_status(rt:run(), 'found')
  assert_eq(rows[2][1], 'v')
  assert_eq(m.entries.k, 'v')
end

local function test_keyed_all_put_does_not_supply_get()
  local rt = new_runtime()
  local m = Keyed.new({}, 'keyed-all')
  local rows
  rt:spawn_raw(function()
    rows = rt:perform(Op.all({ m:put_op('k', 'v'), m:get_op('k'):or_else(Op.always('missing')) }))
  end, 'root')
  assert_status(rt:run(), 'found')
  assert_eq(rows[2][1], 'missing')
  assert_eq(m.entries.k, 'v')
end

local function test_keyed_remove_constrains_get_under_all()
  local rt = new_runtime()
  local m = Keyed.new({ a = 'A', b = 'B' }, 'keyed-remove-all')
  local rows
  rt:spawn_raw(function()
    rows = rt:perform(Op.all({ m:remove_op('a'), m:get_op('a'):or_else(Op.always('missing')) }))
  end, 'root')
  assert_status(rt:run(), 'found')
  assert_eq(rows[2][1], 'missing')
  assert_nil(m.entries.a)
  assert_eq(m.entries.b, 'B')
end

local function test_keyed_remove_present_returns_value()
  local rt = new_runtime()
  local m = Keyed.new({ a = 'A' }, 'keyed-remove-present')
  local v
  rt:spawn_raw(function()
    v = rt:perform(m:remove_present_op('a'))
  end, 'root')
  assert_status(rt:run(), 'found')
  assert_eq(v, 'A')
  assert_nil(m.entries.a)
end

local function test_lease_readers_merge_and_writer_conflicts()
  local rt = new_runtime()
  local c = Lease.new({ read = { read = true }, write = {} }, 'lease-rw')
  local rows
  rt:spawn_raw(function()
    rows = rt:perform(Op.all({ c:acquire_op('s', 'read', 'a'), c:acquire_op('s', 'read', 'b') }))
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

local function test_lease_tensor_release_supplies_acquire_but_all_does_not()
  local c = Lease.new({ read = { read = true }, write = {} }, 'lease-release')
  c.holders.s = { writer = 'write' }
  c.versions.s = 0
  local rt = new_runtime()
  local rows
  rt:spawn_raw(function()
    rows = rt:perform(Op.all({
      c:release_op('s', 'writer'),
      c:acquire_op('s', 'read', 'reader'):or_else(Op.always('blocked')),
    }))
  end, 'root')
  assert_status(rt:run(), 'found')
  assert_eq(rows[2][1], 'blocked')
  assert_nil(c.holders.s.writer)

  c.holders.s = { writer = 'write' }
  c.versions.s = c.versions.s or 0
  local rt2 = new_runtime()
  local rows2
  rt2:spawn_raw(function()
    rows2 =
      rt2:perform(Op.tensor({ c:release_op('s', 'writer'), c:acquire_op('s', 'read', 'reader') }))
  end, 'root')
  assert_status(rt2:run(), 'found')
  assert_eq(rows2[2][1], true)
  assert_eq(c.holders.s.reader, 'read')
end

local function test_priority_queue_order_and_handoff_laws()
  local rt = new_runtime()
  local pq = PriorityQueue.new({ name = 'pq-order' })
  rt:spawn_raw(function()
    rt:perform(Op.all({ pq:put_op(10, 'low'), pq:put_op(1, 'high') }))
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

  local pq2 = PriorityQueue.new({ name = 'pq-law' })
  local rt3 = new_runtime()
  local rows
  rt3:spawn_raw(function()
    rows = rt3:perform(Op.tensor({ pq2:put_op(0, 'urgent'), pq2:get_op() }))
  end, 'root')
  assert_status(rt3:run(), 'found')
  assert_eq(rows[2][1], 'urgent')
  assert_eq(next(pq2.items.entries), nil)

  local pq3 = PriorityQueue.new({ name = 'pq-all' })
  local rt4 = new_runtime()
  local rows4
  rt4:spawn_raw(function()
    rows4 =
      rt4:perform(Op.all({ pq3:put_op(0, 'urgent'), pq3:get_op():or_else(Op.always('empty')) }))
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
    lease = rt:perform(pool:add_op('a', 'A'):and_then(function()
      return pool:acquire_op('u1')
    end))
  end, 'root')
  assert_status(rt:run(), 'found')
  assert_eq(lease.key, 'a')
  assert_eq(lease.item, 'A')
  assert_eq(pool.leases.holders.a.u1, 'lease')

  local rt2 = new_runtime()
  rt2:spawn_raw(function()
    rt2:perform(pool:release_op(lease))
  end, 'root')
  assert_status(rt2:run(), 'found')
  assert_nil(pool.leases.holders.a.u1)
  assert_eq(pool.items.entries.a.item, 'A')
  assert_eq(pool.idle.entries.a.value, 'a')

  local rt3 = new_runtime()
  rt3:spawn_raw(function()
    rt3:perform(pool:retire_op('a', 'bad'))
  end, 'root')
  assert_status(rt3:run(), 'found')
  assert_nil(pool.items.entries.a)
  assert_eq(#retired, 1)
  assert_eq(retired[1].item, 'A')
end

local function test_pool_all_add_does_not_supply_acquire_but_tensor_does()
  local pool = Pool.new({ name = 'pool-law' })
  local rt = new_runtime()
  local rows
  rt:spawn_raw(function()
    rows = rt:perform(
      Op.all({ pool:add_op('x', 'X'), pool:acquire_op('u'):or_else(Op.always('empty')) })
    )
  end, 'root')
  assert_status(rt:run(), 'found')
  assert_eq(rows[2][1], 'empty')
  assert_eq(pool.items.entries.x.item, 'X')
  assert_eq(pool.idle.entries.x.value, 'x')

  local pool2 = Pool.new({ name = 'pool-tensor' })
  local rt2 = new_runtime()
  local rows2
  rt2:spawn_raw(function()
    rows2 = rt2:perform(Op.tensor({ pool2:add_op('x', 'X'), pool2:acquire_op('u') }))
  end, 'root')
  assert_status(rt2:run(), 'found')
  assert_eq(rows2[2][1].item, 'X')
  assert_eq(pool2.items.entries.x.item, 'X')
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
    lease = rt:perform(pool:add_op('a', 'A'):and_then(function()
      return pool:acquire_op('u')
    end))
  end, 'seed')
  assert_status(rt:run(), 'found')
  local rt2 = new_runtime()
  rt2:spawn_raw(function()
    rt2:perform(pool:retire_op('a', 'old'))
  end, 'retire')
  assert_status(rt2:run(), 'found')
  assert_eq(#retired, 0)
  assert_eq(pool.items.entries.a.retire_on_release, true)
  local rt3 = new_runtime()
  rt3:spawn_raw(function()
    rt3:perform(pool:release_op(lease))
  end, 'release')
  assert_status(rt3:run(), 'found')
  assert_eq(#retired, 1)
  assert_nil(pool.items.entries.a)
end

local function test_keyed_remove_present_then_put_replaces()
  local rt = new_runtime()
  local m = Keyed.new({ a = 'A' }, 'keyed-replace-after-remove-present')
  local old
  rt:spawn_raw(function()
    old = rt:perform(m:remove_present_op('a'):and_then(function(v)
      return m:put_op('a', 'A2'):map(function()
        return v
      end)
    end))
  end, 'root')
  assert_status(rt:run(), 'found')
  assert_eq(old, 'A')
  assert_eq(m.entries.a, 'A2')
end

local function test_pool_close_constrains_acquire_under_tensor_and_all()
  local pool = Pool.new({ name = 'pool-close-law' })
  local rt = new_runtime()
  local rows
  rt:spawn_raw(function()
    rows = rt:perform(pool:add_op('a', 'A'):and_then(function()
      return Op.tensor({
        pool:close_op('shutdown'),
        pool:acquire_op('u'):or_else(Op.always('closed')),
      })
    end))
  end, 'root')
  assert_status(rt:run(), 'found')
  assert_eq(rows[2][1], 'closed')
  assert_eq(pool.open.value, false)
  assert_eq(pool.items.entries.a.item, 'A')
  assert_eq(pool.idle.entries.a.value, 'a')

  local pool2 = Pool.new({ name = 'pool-close-law-all' })
  local rt2 = new_runtime()
  local rows2
  rt2:spawn_raw(function()
    rows2 = rt2:perform(pool2:add_op('a', 'A'):and_then(function()
      return Op.all({
        pool2:close_op('shutdown'),
        pool2:acquire_op('u'):or_else(Op.always('closed')),
      })
    end))
  end, 'root')
  assert_status(rt2:run(), 'found')
  assert_eq(rows2[2][1], 'closed')
  assert_eq(pool2.open.value, false)
  assert_eq(pool2.items.entries.a.item, 'A')
  assert_eq(pool2.idle.entries.a.value, 'a')
end

local function test_lease_snapshot_records_structure_validity()
  local rt = new_runtime()
  local c = Lease.new({ read = { read = true }, write = {} }, 'lease-snapshot-validity')
  local snap
  rt:spawn_raw(function()
    snap = rt:perform(c:snapshot_op())
  end, 'root')
  assert_status(rt:run(), 'found')
  assert_eq(snap.version, 0)

  local rt2 = new_runtime()
  rt2:spawn_raw(function()
    rt2:perform(Op.all({ c:snapshot_op(), c:acquire_op('s', 'read', 'a') }))
  end, 'root')
  assert_status(rt2:run(), 'found')
  assert_eq(c.version, 1)
  assert_eq(c.holders.s.a, 'read')
end

local tests = {
  test_keyed_tensor_put_supplies_get,
  test_keyed_all_put_does_not_supply_get,
  test_keyed_remove_constrains_get_under_all,
  test_keyed_remove_present_returns_value,
  test_keyed_remove_present_then_put_replaces,
  test_lease_readers_merge_and_writer_conflicts,
  test_lease_tensor_release_supplies_acquire_but_all_does_not,
  test_priority_queue_order_and_handoff_laws,
  test_pool_acquire_release_and_retirement,
  test_pool_all_add_does_not_supply_acquire_but_tensor_does,
  test_pool_retire_leased_defers_until_release,
  test_pool_close_constrains_acquire_under_tensor_and_all,
  test_lease_snapshot_records_structure_validity,
}

for i = 1, #tests do
  tests[i]()
end

print('tests/test_keyed_lease_priority_pool.lua: ok')

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
local Lease = require('fibers.resource.lease')
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
    fail((msg or 'status mismatch') .. ': expected ' .. tag .. ', got ' .. tostring(st and st.tag))
  end
end
local function new_runtime(opts)
  return Runtime.new(opts or {})
end

local function seed_lease(lease, subject, holders)
  local rt = new_runtime()
  local ops = {}
  for holder, mode in pairs(holders) do ops[#ops + 1] = lease:acquire_op(subject, mode, holder) end
  rt:spawn_raw(function() rt:perform(#ops == 1 and ops[1] or Op.each(ops)) end)
  assert_status(rt:run(), 'found', 'lease seed')
end

local function test_readers_merge_and_writer_conflicts()
  local rt = new_runtime()
  local c = Lease.new({ read = { read = true }, write = {} }, 'lease-rw')
  local rows
  rt:spawn_raw(function()
    rows = rt:perform(Op.each({ c:acquire_op('s', 'read', 'a'), c:acquire_op('s', 'read', 'b') }))
  end)
  assert_status(rt:run(), 'found')
  assert_eq(rows[1][1], true)
  assert_eq(rows[2][1], true)
  assert_eq(c.holders.s.a, 'read')
  assert_eq(c.holders.s.b, 'read')
  local rt2 = new_runtime({ quiet_deadlock = true })
  rt2:spawn_raw(function()
    rt2:perform(c:acquire_op('s', 'write', 'w'))
  end)
  local st = rt2:run()
  if st and st.tag == 'found' then
    fail('writer should not acquire')
  end
end

local function test_release_supply_law()
  local c = Lease.new({ read = { read = true }, write = {} }, 'lease-release')
  seed_lease(c, 's', { writer = 'write' })
  local rt, rows = new_runtime()
  rt:spawn_raw(function()
    rows = rt:perform(Op.each({
      c:release_op('s', 'writer'),
      c:acquire_op('s', 'read', 'reader'):or_else(Op.always('blocked')),
    }))
  end)
  assert_status(rt:run(), 'found')
  assert_eq(rows[2][1], 'blocked')
  assert_nil((c.holders.s or {}).writer)

  seed_lease(c, 's', { writer = 'write' })
  local rt2, rows2 = new_runtime()
  rt2:spawn_raw(function()
    rows2 = rt2:perform(Op.together({ c:release_op('s', 'writer'), c:acquire_op('s', 'read', 'reader') }))
  end)
  assert_status(rt2:run(), 'found')
  assert_eq(rows2[2][1], true)
  assert_eq(c.holders.s.reader, 'read')
  assert_nil((c.holders.s or {}).writer)
end

local function test_incompatible_acquires_do_not_jointly_commit()
  local c = Lease.new({ read = { read = true }, write = {} }, 'lease-incompat')
  local rt = new_runtime({ quiet_deadlock = true })
  rt:spawn_raw(function()
    rt:perform(Op.together({ c:acquire_op('s', 'read', 'r'), c:acquire_op('s', 'write', 'w') }))
  end)
  local st = rt:run()
  if st and st.tag == 'found' then
    fail('incompatible acquisitions committed')
  end
  assert_eq(c.holders.s, nil)
end

local function test_release_one_blocker_not_enough()
  local c = Lease.new({ read = { read = true }, write = {} }, 'lease-two-blockers')
  seed_lease(c, 's', { w1 = 'write', w2 = 'write' })
  local rt, rows = new_runtime()
  rt:spawn_raw(function()
    rows = rt:perform(Op.together({
      c:release_op('s', 'w1'),
      c:acquire_op('s', 'read', 'r'):or_else(Op.always('blocked')),
    }))
  end)
  assert_status(rt:run(), 'found')
  assert_eq(rows[2][1], 'blocked')
  assert_nil((c.holders.s or {}).w1)
  assert_eq(c.holders.s.w2, 'write')
end

local function test_inspection_snapshots_are_detached()
  local c = Lease.new({ read = { read = true }, write = {} }, 'lease-snapshots')
  seed_lease(c, 's', { reader = 'read' })

  local holders = c.holders
  local versions = c.versions
  local version = c.version
  holders.s.reader = 'write'
  versions.s = versions.s + 100

  assert_eq(c.holders.s.reader, 'read', 'holder snapshot must not mutate managed state')
  assert_eq(c.versions.s + 100, versions.s, 'version snapshot must be detached')
  assert_eq(c.version, version, 'snapshot mutation must not change aggregate version')
end


for _, t in ipairs({
  test_readers_merge_and_writer_conflicts,
  test_release_supply_law,
  test_incompatible_acquires_do_not_jointly_commit,
  test_release_one_blocker_not_enough,
  test_inspection_snapshots_are_detached,
}) do
  t()
end
print('tests/test_lease_laws.lua: ok')

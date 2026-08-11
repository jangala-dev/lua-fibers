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
local Index = require('fibers.resource.index')
local ClaimSet = require('fibers.resource.claim_set')
local Runtime = require('fibers.runtime')
local State = require('tests.support.resource_state')
local entries = State.index_entries
local holders = State.claim_holders
local function fail(m)
  error(m, 2)
end
local function eq(a, b, m)
  if a ~= b then
    fail((m or 'not equal') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a))
  end
end
local function found(st)
  eq(st and st.tag, 'found', 'expected found')
end
local function not_found(st, m)
  if st and st.tag == 'found' then
    fail(m or 'unexpected commit')
  end
end
local function rt(opts)
  return Runtime.new(opts or {})
end
local function seed()
  return {
    { key = 'a', rank = 1, value = 'A' },
    { key = 'b', rank = 2, value = 'B' },
    {
      key = 'c',
      rank = 3,
      value = 'C',
    },
  }
end

local function seed_claim_set(lease, subject, holders)
  local r = rt()
  local ops = {}
  for holder, mode in pairs(holders) do ops[#ops + 1] = lease:acquire_op(subject, mode, holder) end
  r:spawn_raw(function() r:perform(#ops == 1 and ops[1] or Op.each(ops)) end)
  found(r:run(), 'claim set seed')
end

local function index_each_hides_better_insert()
  local x = Index.from(seed())
  local r = rt()
  local rows
  r:spawn_raw(function()
    rows = r:perform(Op.each({ x:insert_op('z', 0, 'Z'), x:pop_first_op() }))
  end)
  found(r:run())
  eq(rows[2][1].key, 'a')
  eq(entries(x).z.value, 'Z')
  eq(entries(x).a, nil)
end
local function index_together_uses_better_insert()
  local x = Index.from(seed())
  local r = rt()
  local rows
  r:spawn_raw(function()
    rows = r:perform(Op.together({ x:insert_op('z', 0, 'Z'), x:pop_first_op() }))
  end)
  found(r:run())
  eq(rows[2][1].key, 'z')
  eq(entries(x).z, nil)
  eq(entries(x).a.value, 'A')
end
local function index_mixed_extrema_are_distinct()
  local x = Index.from(seed())
  local r = rt()
  local rows
  r:spawn_raw(function()
    rows = r:perform(Op.together({ x:pop_first_op(), x:pop_last_op(), x:pop_first_op() }))
  end)
  found(r:run())
  eq(rows[1][1].key, 'a')
  eq(rows[2][1].key, 'c')
  eq(rows[3][1].key, 'b')
  eq(next(entries(x)), nil)
end
local function index_duplicate_insert_conflicts()
  local x = Index.new()
  local r = rt({ quiet_deadlock = true })
  r:spawn_raw(function()
    r:perform(Op.together({ x:insert_op('k', 1, 'A'), x:insert_op('k', 2, 'B') }))
  end)
  not_found(r:run(), 'duplicate insert committed')
  eq(next(entries(x)), nil)
end
local function lease_three_readers_form_clique()
  local l = ClaimSet.new({ read = { read = true }, write = {} })
  local r = rt()
  local rows
  r:spawn_raw(function()
    rows = r:perform(Op.each({
      l:acquire_op('s', 'read', 'a'),
      l:acquire_op('s', 'read', 'b'),
      l:acquire_op('s', 'read', 'c'),
    }))
  end)
  found(r:run())
  eq(holders(l, 's').a, 'read')
  eq(holders(l, 's').b, 'read')
  eq(holders(l, 's').c, 'read')
end
local function lease_requires_symmetric_compatibility()
  local l = ClaimSet.new({ a = { b = true }, b = {} })
  local r = rt({ quiet_deadlock = true })
  r:spawn_raw(function()
    r:perform(Op.together({ l:acquire_op('s', 'a', 'x'), l:acquire_op('s', 'b', 'y') }))
  end)
  not_found(r:run(), 'asymmetric compatibility was accepted')
end
local function lease_together_same_owner_is_ordered_upgrade()
  local l = ClaimSet.new({ read = { read = true }, write = {} })
  local r = rt()
  local rows
  r:spawn_raw(function()
    rows = r:perform(Op.together({ l:acquire_op('s', 'read', 'x'), l:acquire_op('s', 'write', 'x') }))
  end)
  found(r:run())
  eq(rows[1][1], true)
  eq(rows[2][1], true)
  eq(holders(l, 's').x, 'write')
end
local function lease_each_same_owner_conflicts()
  local l = ClaimSet.new({ read = { read = true }, write = {} })
  local r = rt({ quiet_deadlock = true })
  r:spawn_raw(function()
    r:perform(Op.each({ l:acquire_op('s', 'read', 'x'), l:acquire_op('s', 'write', 'x') }))
  end)
  not_found(r:run(), 'independent overwrite committed')
end
local function lease_one_release_does_not_remove_other_blocker()
  local l = ClaimSet.new({ read = { read = true }, write = {} })
  seed_claim_set(l, 's', { w1 = 'write', w2 = 'write' })
  local r = rt()
  local rows
  r:spawn_raw(function()
    rows = r:perform(Op.together({
      l:release_op('s', 'w1'),
      l:acquire_op('s', 'read', 'r'):or_else(Op.always('blocked')),
    }))
  end)
  found(r:run())
  eq(rows[2][1], 'blocked')
  eq((holders(l, 's') or {}).w1, nil)
  eq(holders(l, 's').w2, 'write')
end
for _, t in ipairs({
  index_each_hides_better_insert,
  index_together_uses_better_insert,
  index_mixed_extrema_are_distinct,
  index_duplicate_insert_conflicts,
  lease_three_readers_form_clique,
  lease_requires_symmetric_compatibility,
  lease_together_same_owner_is_ordered_upgrade,
  lease_each_same_owner_conflicts,
  lease_one_release_does_not_remove_other_blocker,
}) do
  t()
end
print('tests/test_index_claim_set_extended.lua: ok')

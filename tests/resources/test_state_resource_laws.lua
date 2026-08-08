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
local Counter = require('fibers.resource.counter')
local Keyed = require('fibers.resource.keyed')
local Runtime = require('fibers.runtime')

local function fail(msg)
  error(msg, 2)
end
local function assert_eq(actual, expected, msg)
  if actual ~= expected then
    fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual))
  end
end
local function assert_status(status, tag, msg)
  if not status or status.tag ~= tag then
    fail(
      (msg or 'status mismatch')
        .. ': expected '
        .. tostring(tag)
        .. ', got '
        .. tostring(status and status.tag)
    )
  end
end
local function new_runtime(opts)
  return Runtime.new(opts or {})
end

local function perform_op(op)
  local rt, value = new_runtime()
  rt:spawn_raw(function()
    value = rt:perform(op)
  end)
  assert_status(rt:run(), 'found')
  return value
end

local function assert_key(map, key, expected)
  assert_eq(perform_op(map:contains_op(key)), expected ~= nil)
  if expected ~= nil then
    assert_eq(perform_op(map:get_op(key)), expected)
  end
end

local function test_counter_each_allocates_existing_stock()
  local rt, c, rows = new_runtime(), Counter.new(2)
  rt:spawn_raw(function()
    rows = rt:perform(Op.each({ c:take_op(1), c:take_op(1) }))
  end)
  assert_status(rt:run(), 'found')
  assert_eq(rows[1][1], true)
  assert_eq(rows[2][1], true)
  assert_eq(c._location.value, 0)
end

local function test_counter_each_give_does_not_supply_take()
  local rt, c, rows = new_runtime(), Counter.new(0)
  rt:spawn_raw(function()
    rows = rt:perform(Op.each({ c:give_op(1), c:take_op(1):or_else(Op.always('none')) }))
  end)
  assert_status(rt:run(), 'found')
  assert_eq(rows[2][1], 'none')
  assert_eq(c._location.value, 1)
end

local function test_counter_together_give_supplies_take()
  local rt, c, rows = new_runtime(), Counter.new(0)
  rt:spawn_raw(function()
    rows = rt:perform(Op.together({ c:give_op(1), c:take_op(1) }))
  end)
  assert_status(rt:run(), 'found')
  assert_eq(rows[2][1], true)
  assert_eq(c._location.value, 0)
end

local function test_counter_overdraw_rejected()
  local rt, c = new_runtime({ quiet_deadlock = true }), Counter.new(1)
  rt:spawn_raw(function()
    rt:perform(Op.together({ c:take_op(1), c:take_op(1) }))
  end)
  local st = rt:run()
  if st.tag == 'found' then
    fail('overdraw committed')
  end
  assert_eq(c._location.value, 1)
end

local function test_counter_adjust_is_additive()
  local rt, c = new_runtime(), Counter.new(2)
  rt:spawn_raw(function()
    rt:perform(Op.each({ c:adjust_op(-1), c:adjust_op(2) }))
  end)
  assert_status(rt:run(), 'found')
  assert_eq(c._location.value, 3)
end

local function test_keyed_together_put_supplies_get()
  local rt, m, rows = new_runtime(), Keyed.new()
  rt:spawn_raw(function()
    rows = rt:perform(Op.together({ m:put_op('k', 'v'), m:get_op('k') }))
  end)
  assert_status(rt:run(), 'found')
  assert_eq(rows[2][1], 'v')
  assert_key(m, 'k', 'v')
end

local function test_keyed_each_put_does_not_supply_get()
  local rt, m, rows = new_runtime(), Keyed.new()
  rt:spawn_raw(function()
    rows = rt:perform(Op.each({ m:put_op('k', 'v'), m:get_op('k'):or_else(Op.always('missing')) }))
  end)
  assert_status(rt:run(), 'found')
  assert_eq(rows[2][1], 'missing')
  assert_key(m, 'k', 'v')
end

local function test_keyed_remove_and_get_share_parent_value()
  local rt, m, rows = new_runtime(), Keyed.from({ a = 'A', b = 'B' })
  rt:spawn_raw(function()
    rows = rt:perform(Op.each({ m:remove_op('a'), m:get_op('a'):or_else(Op.always('missing')) }))
  end)
  assert_status(rt:run(), 'found')
  assert_eq(rows[1][1], true)
  assert_eq(rows[2][1], 'A')
  assert_key(m, 'a', nil)
  assert_key(m, 'b', 'B')
end

local function test_keyed_take_returns_value()
  local rt, m, value = new_runtime(), Keyed.from({ a = 'A' })
  rt:spawn_raw(function()
    value = rt:perform(m:take_op('a'))
  end)
  assert_status(rt:run(), 'found')
  assert_eq(value, 'A')
  assert_key(m, 'a', nil)
end

local function test_keyed_take_then_put_replaces()
  local rt, m, old = new_runtime(), Keyed.from({ a = 'A' })
  rt:spawn_raw(function()
    old = rt:perform(m:take_op('a'):and_then(Op.guard(function(v)
      return m:put_op('a', 'A2'):map(function()
        return v
      end)
    end)))
  end)
  assert_status(rt:run(), 'found')
  assert_eq(old, 'A')
  assert_key(m, 'a', 'A2')
end

-- This is the first operation which requires a partial claim to consume a
-- value supplied by a sibling in `together`, rather than merely observe it.
local function test_keyed_together_put_supplies_take()
  local rt, m, rows = new_runtime(), Keyed.new()
  rt:spawn_raw(function()
    rows = rt:perform(Op.together({ m:put_op('k', 'v'), m:take_op('k') }))
  end)
  assert_status(rt:run(), 'found')
  assert_eq(rows[2][1], 'v')
  assert_key(m, 'k', nil)
end

local function test_keyed_each_put_does_not_supply_take()
  local rt, m, rows = new_runtime(), Keyed.new()
  rt:spawn_raw(function()
    rows = rt:perform(Op.each({ m:put_op('k', 'v'), m:take_op('k'):or_else(Op.always('missing')) }))
  end)
  assert_status(rt:run(), 'found')
  assert_eq(rows[2][1], 'missing')
  assert_key(m, 'k', 'v')
end

local function test_keyed_two_consumers_do_not_duplicate_one_value()
  local rt, m = new_runtime({ quiet_deadlock = true }), Keyed.from({ k = 'v' })
  rt:spawn_raw(function()
    rt:perform(Op.together({ m:take_op('k'), m:take_op('k') }))
  end)
  local st = rt:run()
  if st.tag == 'found' then
    fail('two consumers duplicated one keyed value')
  end
  assert_key(m, 'k', 'v')
end

local function test_keyed_each_insert_does_not_supply_get()
  local rt, m, rows = new_runtime(), Keyed.new()
  rt:spawn_raw(function()
    rows = rt:perform(Op.each({ m:insert_op('k', 'v'), m:get_op('k'):or_else(Op.always('missing')) }))
  end)
  assert_status(rt:run(), 'found')
  assert_eq(rows[1][1], true)
  assert_eq(rows[2][1], 'missing')
  assert_key(m, 'k', 'v')
end

local function test_keyed_together_insert_supplies_get()
  local rt, m, rows = new_runtime(), Keyed.new()
  rt:spawn_raw(function()
    rows = rt:perform(Op.together({ m:insert_op('k', 'v'), m:get_op('k') }))
  end)
  assert_status(rt:run(), 'found')
  assert_eq(rows[1][1], true)
  assert_eq(rows[2][1], 'v')
  assert_key(m, 'k', 'v')
end

local function test_keyed_rejects_nil_values()
  local map = Keyed.new()

  for _, operation in ipairs({ 'put_op', 'insert_op' }) do
    local ok, err = pcall(function()
      map[operation](map, 'k', nil)
    end)
    assert_eq(ok, false)
    if not tostring(err):find('keyed values cannot be nil', 1, true) then
      fail('unexpected nil-value error: ' .. tostring(err))
    end
  end
end

local function test_keyed_insert_requires_absence()
  local map = Keyed.from({ k = 'old' })
  local rt = new_runtime({ quiet_deadlock = true })
  rt:spawn_raw(function()
    rt:perform(map:insert_op('k', 'new'))
  end)
  if rt:run().tag == 'found' then
    fail('insert replaced an existing keyed value')
  end
  assert_key(map, 'k', 'old')
end

local function test_keyed_proof_conveniences()
  local map = Keyed.new()
  assert_eq(perform_op(map:contains_op('missing')), false)
  assert_eq(perform_op(map:remove_op('missing')), false)

  perform_op(map:put_op('present', 'value'))
  assert_eq(perform_op(map:contains_op('present')), true)
  assert_eq(perform_op(map:remove_op('present')), true)
  assert_eq(perform_op(map:contains_op('present')), false)
end

local tests = {
  test_counter_each_allocates_existing_stock,
  test_counter_each_give_does_not_supply_take,
  test_counter_together_give_supplies_take,
  test_counter_overdraw_rejected,
  test_counter_adjust_is_additive,
  test_keyed_together_put_supplies_get,
  test_keyed_each_put_does_not_supply_get,
  test_keyed_remove_and_get_share_parent_value,
  test_keyed_take_returns_value,
  test_keyed_take_then_put_replaces,
  test_keyed_together_put_supplies_take,
  test_keyed_each_put_does_not_supply_take,
  test_keyed_two_consumers_do_not_duplicate_one_value,
  test_keyed_each_insert_does_not_supply_get,
  test_keyed_together_insert_supplies_get,
  test_keyed_rejects_nil_values,
  test_keyed_insert_requires_absence,
  test_keyed_proof_conveniences,
}

for i = 1, #tests do
  tests[i]()
end
print('tests/test_state_resource_laws.lua: ok')

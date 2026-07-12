package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

local Op = require('fibers.atoms.op')
local Counter = require('fibers.atoms.counter')
local Keyed = require('fibers.atoms.keyed')
local Runtime = require('fibers.kernel.runtime')

local function fail(msg) error(msg, 2) end
local function assert_eq(actual, expected, msg)
  if actual ~= expected then fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual)) end
end
local function assert_nil(actual, msg) if actual ~= nil then fail((msg or 'assert_nil failed') .. ': got ' .. tostring(actual)) end end
local function assert_status(status, tag, msg)
  if not status or status.tag ~= tag then fail((msg or 'status mismatch') .. ': expected ' .. tostring(tag) .. ', got ' .. tostring(status and status.tag)) end
end
local function new_runtime(opts) return Runtime.new(opts or {}) end

local function test_counter_all_allocates_existing_stock()
  local rt, c, rows = new_runtime(), Counter.new({ initial = 2, min = 0 })
  rt:spawn_raw(function() rows = rt:perform(Op.all({ c:take_op(1), c:take_op(1) })) end)
  assert_status(rt:run(), 'found'); assert_eq(rows[1][1], true); assert_eq(rows[2][1], true); assert_eq(c.value, 0)
end

local function test_counter_all_give_does_not_supply_take()
  local rt, c, rows = new_runtime(), Counter.new({ initial = 0, min = 0 })
  rt:spawn_raw(function() rows = rt:perform(Op.all({ c:give_op(1), c:take_op(1):or_else(Op.always('none')) })) end)
  assert_status(rt:run(), 'found'); assert_eq(rows[2][1], 'none'); assert_eq(c.value, 1)
end

local function test_counter_tensor_give_supplies_take()
  local rt, c, rows = new_runtime(), Counter.new({ initial = 0, min = 0 })
  rt:spawn_raw(function() rows = rt:perform(Op.tensor({ c:give_op(1), c:take_op(1) })) end)
  assert_status(rt:run(), 'found'); assert_eq(rows[2][1], true); assert_eq(c.value, 0)
end

local function test_counter_overdraw_rejected()
  local rt, c = new_runtime({ quiet_deadlock = true }), Counter.new({ initial = 1, min = 0 })
  rt:spawn_raw(function() rt:perform(Op.tensor({ c:take_op(1), c:take_op(1) })) end)
  local st = rt:run(); if st.tag == 'found' then fail('overdraw committed') end; assert_eq(c.value, 1)
end

local function test_counter_adjust_is_additive()
  local rt, c = new_runtime(), Counter.new({ initial = 2, min = 0 })
  rt:spawn_raw(function() rt:perform(Op.all({ c:adjust_op(-1), c:adjust_op(2) })) end)
  assert_status(rt:run(), 'found'); assert_eq(c.value, 3)
end

local function test_keyed_tensor_put_supplies_get()
  local rt, m, rows = new_runtime(), Keyed.new({})
  rt:spawn_raw(function() rows = rt:perform(Op.tensor({ m:put_op('k', 'v'), m:get_op('k') })) end)
  assert_status(rt:run(), 'found'); assert_eq(rows[2][1], 'v'); assert_eq(m.entries.k, 'v')
end

local function test_keyed_all_put_does_not_supply_get()
  local rt, m, rows = new_runtime(), Keyed.new({})
  rt:spawn_raw(function() rows = rt:perform(Op.all({ m:put_op('k', 'v'), m:get_op('k'):or_else(Op.always('missing')) })) end)
  assert_status(rt:run(), 'found'); assert_eq(rows[2][1], 'missing'); assert_eq(m.entries.k, 'v')
end

local function test_keyed_remove_constrains_get_under_all()
  local rt, m, rows = new_runtime(), Keyed.new({ a = 'A', b = 'B' })
  rt:spawn_raw(function() rows = rt:perform(Op.all({ m:remove_op('a'), m:get_op('a'):or_else(Op.always('missing')) })) end)
  assert_status(rt:run(), 'found'); assert_eq(rows[2][1], 'missing'); assert_nil(m.entries.a); assert_eq(m.entries.b, 'B')
end

local function test_keyed_remove_present_returns_value()
  local rt, m, value = new_runtime(), Keyed.new({ a = 'A' })
  rt:spawn_raw(function() value = rt:perform(m:remove_present_op('a')) end)
  assert_status(rt:run(), 'found'); assert_eq(value, 'A'); assert_nil(m.entries.a)
end

local function test_keyed_remove_present_then_put_replaces()
  local rt, m, old = new_runtime(), Keyed.new({ a = 'A' })
  rt:spawn_raw(function()
    old = rt:perform(m:remove_present_op('a'):and_then(function(v)
      return m:put_op('a', 'A2'):map(function() return v end)
    end))
  end)
  assert_status(rt:run(), 'found'); assert_eq(old, 'A'); assert_eq(m.entries.a, 'A2')
end

-- This is the first operation which requires a partial claim to consume a
-- value supplied by a tensor sibling, rather than merely observe it.
local function test_keyed_tensor_put_supplies_remove_present()
  local rt, m, rows = new_runtime(), Keyed.new({})
  rt:spawn_raw(function() rows = rt:perform(Op.tensor({ m:put_op('k', 'v'), m:remove_present_op('k') })) end)
  assert_status(rt:run(), 'found'); assert_eq(rows[2][1], 'v'); assert_nil(m.entries.k)
end


local function test_keyed_all_put_does_not_supply_remove_present()
  local rt, m, rows = new_runtime(), Keyed.new({})
  rt:spawn_raw(function()
    rows = rt:perform(Op.all({ m:put_op('k', 'v'), m:remove_present_op('k'):or_else(Op.always('missing')) }))
  end)
  assert_status(rt:run(), 'found'); assert_eq(rows[2][1], 'missing'); assert_eq(m.entries.k, 'v')
end

local function test_keyed_two_consumers_do_not_duplicate_one_value()
  local rt, m = new_runtime({ quiet_deadlock = true }), Keyed.new({ k = 'v' })
  rt:spawn_raw(function() rt:perform(Op.tensor({ m:remove_present_op('k'), m:remove_present_op('k') })) end)
  local st = rt:run(); if st.tag == 'found' then fail('two consumers duplicated one keyed value') end
  assert_eq(m.entries.k, 'v')
end


local function test_keyed_all_partial_put_does_not_supply_partial_get()
  local rt, m, rows = new_runtime(), Keyed.new({})
  rt:spawn_raw(function()
    rows = rt:perform(Op.all({ m:put_absent_op('k', 'v'), m:get_op('k'):or_else(Op.always('missing')) }))
  end)
  assert_status(rt:run(), 'found'); assert_eq(rows[1][1], true); assert_eq(rows[2][1], 'missing'); assert_eq(m.entries.k, 'v')
end

local function test_keyed_tensor_partial_put_supplies_partial_get()
  local rt, m, rows = new_runtime(), Keyed.new({})
  rt:spawn_raw(function()
    rows = rt:perform(Op.tensor({ m:put_absent_op('k', 'v'), m:get_op('k') }))
  end)
  assert_status(rt:run(), 'found'); assert_eq(rows[1][1], true); assert_eq(rows[2][1], 'v'); assert_eq(m.entries.k, 'v')
end


local tests = {
  test_counter_all_allocates_existing_stock,
  test_counter_all_give_does_not_supply_take,
  test_counter_tensor_give_supplies_take,
  test_counter_overdraw_rejected,
  test_counter_adjust_is_additive,
  test_keyed_tensor_put_supplies_get,
  test_keyed_all_put_does_not_supply_get,
  test_keyed_remove_constrains_get_under_all,
  test_keyed_remove_present_returns_value,
  test_keyed_remove_present_then_put_replaces,
  test_keyed_tensor_put_supplies_remove_present,
  test_keyed_all_put_does_not_supply_remove_present,
  test_keyed_two_consumers_do_not_duplicate_one_value,
  test_keyed_all_partial_put_does_not_supply_partial_get,
  test_keyed_tensor_partial_put_supplies_partial_get,
}

for i = 1, #tests do tests[i]() end
print('tests/test_state_resource_laws.lua: ok')

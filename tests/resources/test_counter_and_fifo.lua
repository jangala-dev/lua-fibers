-- Premise-aware Counter and FIFO built from Index + Counter.

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
local FIFO = require('fibers.resource.fifo')
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

local function test_counter_each_allocates_existing_stock()
  local rt = new_runtime()
  local c = Counter.new(2):label('ctr-each-take')
  local rows
  rt:spawn_raw(function()
    rows = rt:perform(Op.each({ c:take_op(1), c:take_op(1) }))
  end):label('root')
  assert_status(rt:run(), 'found')
  assert_eq(rows[1][1], true)
  assert_eq(rows[2][1], true)
  assert_eq(c._location.value, 0)
end

local function test_counter_each_give_does_not_supply_sibling_take()
  local rt = new_runtime()
  local c = Counter.new(0):label('ctr-each-give-take')
  local rows
  rt:spawn_raw(function()
    rows = rt:perform(Op.each({
      c:give_op(1),
      c:take_op(1):or_else(Op.always('none')),
    }))
  end):label('root')
  assert_status(rt:run(), 'found')
  assert_eq(rows[1][1], true)
  assert_eq(rows[2][1], 'none')
  assert_eq(c._location.value, 1)
end

local function test_counter_together_give_supplies_sibling_take()
  local rt = new_runtime()
  local c = Counter.new(0):label('ctr-together-give-take')
  local rows
  rt:spawn_raw(function()
    rows = rt:perform(Op.together({
      c:give_op(1),
      c:take_op(1),
    }))
  end):label('root')
  assert_status(rt:run(), 'found')
  assert_eq(rows[1][1], true)
  assert_eq(rows[2][1], true)
  assert_eq(c._location.value, 0)
end

local function test_counter_overdraw_fails_as_one_world()
  local rt = new_runtime({ quiet_deadlock = true })
  local c = Counter.new(1):label('ctr-overdraw')
  rt:spawn_raw(function()
    rt:perform(Op.together({ c:take_op(1), c:take_op(1) }))
  end):label('root')
  local status = rt:run()
  if status and status.tag == 'found' then
    fail('overdrawn counter together should not commit')
  end
  assert_eq(c._location.value, 1)
end

local function test_counter_add_is_positive_and_adjust_is_signed()
  local c = Counter.new(2):label('ctr-api')
  local ok = pcall(function()
    c:add_op(-1)
  end)
  if ok then
    fail('counter add_op should reject negative amounts')
  end

  local rt = new_runtime()
  rt:spawn_raw(function()
    rt:perform(c:adjust_op(-1))
  end):label('root')
  assert_status(rt:run(), 'found')
  assert_eq(c._location.value, 1)
end


local function test_counter_zero_amount_is_identity()
  local rt = new_runtime()
  local c = Counter.new(2):label('ctr-zero-identity')
  local adjusted, taken, final
  rt:spawn_raw(function()
    adjusted = rt:perform(c:adjust_op(0))
    taken = rt:perform(c:take_op(0))
    final = rt:perform(c:read_op())
  end):label('root')
  assert_status(rt:run(), 'found')
  assert_eq(adjusted, true)
  assert_eq(taken, true)
  assert_eq(final, 2)
end

local function test_fifo_together_put_supplies_get()
  local rt = new_runtime()
  local q = FIFO.new(math.huge):label('q-together')
  local rows
  rt:spawn_raw(function()
    rows = rt:perform(Op.together({
      q:put_op('x'),
      q:get_op(),
    }))
  end):label('root')
  assert_status(rt:run(), 'found')
  assert_eq(rows[1][1], true)
  assert_eq(rows[2][1], 'x')
  local empty
  local rt2 = new_runtime()
  rt2:spawn_raw(function()
    empty = rt2:perform(q:get_op():or_else(Op.always('empty')))
  end):label('empty-check')
  assert_status(rt2:run(), 'found')
  assert_eq(empty, 'empty')
end

local function test_fifo_each_put_does_not_supply_get()
  local rt = new_runtime()
  local q = FIFO.new(math.huge):label('q-each')
  local rows
  rt:spawn_raw(function()
    rows = rt:perform(Op.each({
      q:put_op('x'),
      q:get_op():or_else(Op.always('empty')),
    }))
  end):label('root')
  assert_status(rt:run(), 'found')
  assert_eq(rows[1][1], true)
  assert_eq(rows[2][1], 'empty')
  local stored
  local rt2 = new_runtime()
  rt2:spawn_raw(function()
    stored = rt2:perform(q:get_op())
  end):label('stored-get')
  assert_status(rt2:run(), 'found')
  assert_eq(stored, 'x')
end

local function test_fifo_each_gets_allocate_existing_stock()
  local rt = new_runtime()
  local q = FIFO.new(math.huge):label('q-each-existing')
  local rows
  rt:spawn_raw(function()
    rt:perform(q:put_op('a'))
    rt:perform(q:put_op('b'))
    rows = rt:perform(Op.each({ q:get_op(), q:get_op() }))
  end):label('root')
  assert_status(rt:run(), 'found')
  assert_eq(rows[1][1], 'a')
  assert_eq(rows[2][1], 'b')
end

local function test_bounded_fifo_capacity_and_release()
  local rt = new_runtime()
  local q = FIFO.new(1):label('q-bounded')
  local rows
  rt:spawn_raw(function()
    rows = rt:perform(Op.together({
      q:put_op('x'),
      q:get_op(),
    }))
  end):label('root')
  assert_status(rt:run(), 'found')
  assert_eq(rows[2][1], 'x')
  local round_trip
  local rt2 = new_runtime()
  rt2:spawn_raw(function()
    rt2:perform(q:put_op('y'))
    round_trip = rt2:perform(q:get_op())
  end):label('capacity-reused')
  assert_status(rt2:run(), 'found')
  assert_eq(round_trip, 'y', 'put/get handoff should release capacity')
end

local function test_fifo_put_op_construction_does_not_mutate_state()
  local q = FIFO.new(math.huge):label('q-construction')
  local op1 = q:put_op('lost')
  local op2 = q:put_op('won')
  local rt = new_runtime({ choice_seed = 2 })
  local out
  rt:spawn_raw(function()
    out = rt:perform(Op.choice({ Op.always('skip'), op1 }))
  end):label('root')
  assert_status(rt:run(), 'found')
  assert_eq(out, 'skip')

  local rt2 = new_runtime()
  rt2:spawn_raw(function()
    rt2:perform(op2)
  end):label('root')
  assert_status(rt2:run(), 'found')
  local only
  local rt3 = new_runtime()
  rt3:spawn_raw(function()
    only = rt3:perform(q:get_op())
  end):label('won-get')
  assert_status(rt3:run(), 'found')
  assert_eq(only, 'won')
end

local function test_fifo_capacity_surface()
  local unbounded = FIFO.new(math.huge):label('unbounded')
  assert_eq(unbounded.capacity, math.huge)

  if pcall(FIFO.new, -1) then
    fail('negative FIFO capacity should fail')
  end
  if pcall(FIFO.new, 1.5) then
    fail('fractional FIFO capacity should fail')
  end
end

local tests = {
  test_counter_each_allocates_existing_stock,
  test_counter_each_give_does_not_supply_sibling_take,
  test_counter_together_give_supplies_sibling_take,
  test_counter_overdraw_fails_as_one_world,
  test_counter_add_is_positive_and_adjust_is_signed,
  test_counter_zero_amount_is_identity,
  test_fifo_together_put_supplies_get,
  test_fifo_each_put_does_not_supply_get,
  test_fifo_each_gets_allocate_existing_stock,
  test_bounded_fifo_capacity_and_release,
  test_fifo_put_op_construction_does_not_mutate_state,
  test_fifo_capacity_surface,
}

for i = 1, #tests do
  tests[i]()
end

print('tests/resources/test_counter_and_fifo.lua: ok')

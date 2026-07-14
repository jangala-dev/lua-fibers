-- Premise-aware Counter and Queue built from Index + Counter.

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

local Op = require('fibers.op')
local Counter = require('fibers.resource.counter')
local Queue = require('fibers.internal.fifo')
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

local function test_counter_all_allocates_existing_stock()
  local rt = new_runtime()
  local c = Counter.new({ initial = 2, min = 0 }, 'ctr-all-take')
  local rows
  rt:spawn_raw(function()
    rows = rt:perform(Op.all({ c:take_op(1), c:take_op(1) }))
  end, 'root')
  assert_status(rt:run(), 'found')
  assert_eq(rows[1][1], true)
  assert_eq(rows[2][1], true)
  assert_eq(c.value, 0)
end

local function test_counter_all_give_does_not_supply_sibling_take()
  local rt = new_runtime()
  local c = Counter.new({ initial = 0, min = 0 }, 'ctr-all-give-take')
  local rows
  rt:spawn_raw(function()
    rows = rt:perform(Op.all({
      c:give_op(1),
      c:take_op(1):or_else(Op.always('none')),
    }))
  end, 'root')
  assert_status(rt:run(), 'found')
  assert_eq(rows[1][1], true)
  assert_eq(rows[2][1], 'none')
  assert_eq(c.value, 1)
end

local function test_counter_tensor_give_supplies_sibling_take()
  local rt = new_runtime()
  local c = Counter.new({ initial = 0, min = 0 }, 'ctr-tensor-give-take')
  local rows
  rt:spawn_raw(function()
    rows = rt:perform(Op.tensor({
      c:give_op(1),
      c:take_op(1),
    }))
  end, 'root')
  assert_status(rt:run(), 'found')
  assert_eq(rows[1][1], true)
  assert_eq(rows[2][1], true)
  assert_eq(c.value, 0)
end

local function test_counter_overdraw_fails_as_one_world()
  local rt = new_runtime({ quiet_deadlock = true })
  local c = Counter.new({ initial = 1, min = 0 }, 'ctr-overdraw')
  rt:spawn_raw(function()
    rt:perform(Op.tensor({ c:take_op(1), c:take_op(1) }))
  end, 'root')
  local status = rt:run()
  if status and status.tag == 'found' then
    fail('overdrawn counter tensor should not commit')
  end
  assert_eq(c.value, 1)
end

local function test_counter_add_is_positive_and_adjust_is_signed()
  local c = Counter.new({ initial = 2, min = 0 }, 'ctr-api')
  local ok = pcall(function()
    c:add_op(-1)
  end)
  if ok then
    fail('counter add_op should reject negative amounts')
  end

  local rt = new_runtime()
  rt:spawn_raw(function()
    rt:perform(c:adjust_op(-1))
  end, 'root')
  assert_status(rt:run(), 'found')
  assert_eq(c.value, 1)
end

local function test_queue_tensor_put_supplies_get()
  local rt = new_runtime()
  local q = Queue.new({ name = 'q-tensor' })
  local rows
  rt:spawn_raw(function()
    rows = rt:perform(Op.tensor({
      q:put_op('x'),
      q:get_op(),
    }))
  end, 'root')
  assert_status(rt:run(), 'found')
  assert_eq(rows[1][1], true)
  assert_eq(rows[2][1], 'x')
  assert_eq(next(q.items.entries), nil, 'tensor put/get should leave unbounded queue empty')
end

local function test_queue_all_put_does_not_supply_get()
  local rt = new_runtime()
  local q = Queue.new({ name = 'q-all' })
  local rows
  rt:spawn_raw(function()
    rows = rt:perform(Op.all({
      q:put_op('x'),
      q:get_op():or_else(Op.always('empty')),
    }))
  end, 'root')
  assert_status(rt:run(), 'found')
  assert_eq(rows[1][1], true)
  assert_eq(rows[2][1], 'empty')
  local only
  for _, e in pairs(q.items.entries) do
    only = e
  end
  assert_eq(only.value, 'x')
end

local function test_queue_all_gets_allocate_existing_stock()
  local rt = new_runtime()
  local q = Queue.new({ name = 'q-all-existing' })
  q.items.entries[1] = { key = 1, rank = 1, seq = 1, value = 'a' }
  q.items.entries[2] = { key = 2, rank = 2, seq = 2, value = 'b' }
  local rows
  rt:spawn_raw(function()
    rows = rt:perform(Op.all({ q:get_op(), q:get_op() }))
  end, 'root')
  assert_status(rt:run(), 'found')
  assert_eq(rows[1][1], 'a')
  assert_eq(rows[2][1], 'b')
  assert_eq(next(q.items.entries), nil)
end

local function test_bounded_queue_capacity_and_release()
  local rt = new_runtime()
  local q = Queue.new({ capacity = 1, name = 'q-bounded' })
  local rows
  rt:spawn_raw(function()
    rows = rt:perform(Op.tensor({
      q:put_op('x'),
      q:get_op(),
    }))
  end, 'root')
  assert_status(rt:run(), 'found')
  assert_eq(rows[2][1], 'x')
  assert_eq(q.slots.value, 1, 'put/get handoff should release capacity')
  assert_eq(next(q.items.entries), nil)
end

local function test_queue_put_op_construction_does_not_mutate_queue_state()
  local q = Queue.new({ name = 'q-construction' })
  local op1 = q:put_op('lost')
  local op2 = q:put_op('won')
  assert_eq(next(q.items.entries), nil, 'constructing put_op should not insert into the queue')
  local rt = new_runtime({ choice_seed = 2 })
  local out
  rt:spawn_raw(function()
    out = rt:perform(Op.choice({ Op.always('skip'), op1 }))
  end, 'root')
  assert_status(rt:run(), 'found')
  assert_eq(out, 'skip')
  assert_eq(next(q.items.entries), nil, 'losing put_op branch should not mutate queue')

  local rt2 = new_runtime()
  rt2:spawn_raw(function()
    rt2:perform(op2)
  end, 'root')
  assert_status(rt2:run(), 'found')
  local only
  for _, e in pairs(q.items.entries) do
    only = e
  end
  assert_eq(only.value, 'won')
end

local tests = {
  test_counter_all_allocates_existing_stock,
  test_counter_all_give_does_not_supply_sibling_take,
  test_counter_tensor_give_supplies_sibling_take,
  test_counter_overdraw_fails_as_one_world,
  test_counter_add_is_positive_and_adjust_is_signed,
  test_queue_tensor_put_supplies_get,
  test_queue_all_put_does_not_supply_get,
  test_queue_all_gets_allocate_existing_stock,
  test_bounded_queue_capacity_and_release,
  test_queue_put_op_construction_does_not_mutate_queue_state,
}

for i = 1, #tests do
  tests[i]()
end

print('tests/test_counter_queue.lua: ok')

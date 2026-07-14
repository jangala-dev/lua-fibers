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

local fibers = require('fibers')
local FibersOp = require('fibers.op')
local FibersCalendar = require('examples.case_studies.calendar.calendar')
local Op, Calendar = FibersOp, FibersCalendar

local function run(fn)
  fibers.run(fn, { quiet_deadlock = true })
end

local function reservation_count(calendar)
  local n = 0
  for _ in pairs(calendar:snapshot()) do
    n = n + 1
  end
  return n
end

-- Atomic reservation across several resources.
do
  local cal = Calendar.new()
  local r
  run(function()
    r = fibers.perform(cal:reserve_at_op({ 'room', 'alice' }, 10, 11, 'meeting'))
  end)
  assert(r.start == 10 and r.finish == 11 and r.payload == 'meeting')
  assert(reservation_count(cal) == 1)
end

-- Overlap on any shared resource blocks and enables immediate fallback.
do
  local cal = Calendar.new({ { id = 1, start = 10, finish = 11, resources = { 'room', 'alice' } } })
  local result
  run(function()
    result = fibers.perform(cal:reserve_at_op({ 'alice', 'bob' }, 10, 11):or_else(Op.always('busy')))
  end)
  assert(result == 'busy' and reservation_count(cal) == 1)
end

-- Disjoint resources and adjacent intervals compose independently.
do
  local cal = Calendar.new()
  local rows
  run(function()
    rows = fibers.perform(Op.all({
      cal:reserve_at_op({ 'a' }, 0, 5),
      cal:reserve_at_op({ 'a' }, 5, 10),
      cal:reserve_at_op({ 'b' }, 0, 10),
    }))
  end)
  assert(rows[1][1].start == 0 and rows[2][1].start == 5 and rows[3][1].start == 0)
  assert(reservation_count(cal) == 3)
end

-- Calendar slot witnesses are globally backtrackable.  The flexible request
-- first proposes 0, but must move to 5 so the fixed request can use 0.
do
  local cal = Calendar.new()
  local rows
  run(function()
    rows = fibers.perform(Op.all({
      cal:reserve_op({
        resources = { 'room' },
        earliest = 0,
        latest = 10,
        duration = 5,
        starts = { 0, 5 },
      }),
      cal:reserve_at_op({ 'room' }, 0, 5),
    }))
  end)
  assert(rows[1][1].start == 5 and rows[2][1].start == 0)
  assert(reservation_count(cal) == 2)
end

-- Cancellation supplies a blocked reservation only through tensor.
do
  local cal = Calendar.new({ { id = 1, start = 0, finish = 5, resources = { 'room' } } })
  local rows
  run(function()
    rows = fibers.perform(Op.tensor({ cal:cancel_op(1), cal:reserve_at_op({ 'room' }, 0, 5) }))
  end)
  assert(rows[1][1].id == 1 and rows[2][1].start == 0)
  assert(reservation_count(cal) == 1 and cal:snapshot()[1] == nil)
end

do
  local cal = Calendar.new({ { id = 1, start = 0, finish = 5, resources = { 'room' } } })
  local result
  run(function()
    result = fibers.perform(
      Op.all({ cal:cancel_op(1), cal:reserve_at_op({ 'room' }, 0, 5) }):or_else(Op.always('fallback'))
    )
  end)
  assert(result == 'fallback')
  assert(reservation_count(cal) == 1 and cal:snapshot()[1] ~= nil)
end

-- Earliest-slot search uses interval boundaries as a finite complete witness set.
do
  local cal = Calendar.new({
    { id = 1, start = 0, finish = 3, resources = { 'room' } },
    { id = 2, start = 5, finish = 7, resources = { 'room' } },
  })
  local r
  run(function()
    r = fibers.perform(cal:reserve_op({ resources = { 'room' }, earliest = 0, latest = 10, duration = 2 }))
  end)
  assert(r.start == 3 and r.finish == 5)
end

-- A non-writing search has the same witness order but leaves the schedule unchanged.
do
  local cal = Calendar.new()
  local slot
  run(function()
    slot = fibers.perform(cal:find_op({ resources = { 'room' }, earliest = 4, latest = 12, duration = 3 }))
  end)
  assert(slot.start == 4 and slot.finish == 7 and reservation_count(cal) == 0)
end

print('tests/test_calendar.lua: ok')

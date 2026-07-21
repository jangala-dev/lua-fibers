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

local Machine = require('fibers.internal.kernel.machine')
local Trail = assert(Machine._Trail, 'production trail test seam is missing')

local stats = {}
local plan = {
  trail_entries = 0,
  trail_set_coalesced = 0,
  trail_push_coalesced = 0,
  max_trail = 0,
  rollbacks = 0,
  rollback_entries = 0,
}
local trail = Trail.new(stats, plan)
local record = { value = 0 }
local values = {}

local outer = trail:mark()
trail:set(record, 'value', 1)
trail:set(record, 'value', 2)
trail:push(values, 'a')
trail:push(values, 'b')

local inner = trail:mark()
trail:set(record, 'value', 3)
trail:set(record, 'value', 4)
trail:push(values, 'c')
trail:push(values, 'd')

assert(record.value == 4)
assert(#values == 4)
assert(plan.trail_entries == 4, 'one set and one push entry should be retained per mark')
assert(plan.trail_set_coalesced == 2)
assert(plan.trail_push_coalesced == 2)

trail:rollback(inner)
assert(record.value == 2, 'inner rollback did not restore the outer value')
assert(#values == 2 and values[1] == 'a' and values[2] == 'b')

-- The parent's first-write stamp must survive a nested rollback.
trail:set(record, 'value', 5)
trail:push(values, 'e')
assert(plan.trail_entries == 4, 'parent writes after nested rollback should remain coalesced')
assert(plan.trail_set_coalesced == 3)
assert(plan.trail_push_coalesced == 3)

trail:rollback(outer)
assert(record.value == 0)
assert(#values == 0)
assert(trail.n == 0 and trail.current_mark == 0)
assert(plan.rollbacks == 2)
assert(plan.rollback_entries == 4)

-- Reset must clear stamps before the trail is reused by a pooled session.
trail:reset(stats, plan)
local again = trail:mark()
trail:set(record, 'value', 7)
trail:push(values, 'x')
assert(plan.trail_entries == 6)
trail:rollback(again)
assert(record.value == 0 and #values == 0)

print('tests/kernel/test_trail_journal.lua: ok')

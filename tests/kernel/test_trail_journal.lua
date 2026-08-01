package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

local Journal = require('fibers.internal.kernel.journal')

local trail = Journal.new()
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
assert(trail:size() == 4)

trail:rollback(inner)
assert(record.value == 2, 'inner rollback did not restore the outer value')
assert(#values == 2 and values[1] == 'a' and values[2] == 'b')

-- The parent's first-write stamp must survive a nested rollback.
trail:set(record, 'value', 5)
trail:push(values, 'e')
assert(trail:size() == 2, 'parent writes after nested rollback should remain coalesced')

trail:rollback(outer)
assert(record.value == 0)
assert(#values == 0)
assert(trail:size() == 0 and trail.current == 0)

-- Reset must clear stamps before the trail is reused by a later search.
trail:reset()
local again = trail:mark()
trail:set(record, 'value', 7)
trail:push(values, 'x')
assert(trail:size() == 2)
trail:rollback(again)
assert(record.value == 0 and #values == 0)

-- Commit calculates every final value before installing any of them. A later
-- algebra failure must therefore leave all committed values and versions intact.
do
  local add = {
    name = 'test-add',
    apply = function(_, value, patch) return value + patch.delta end,
    stage = function(_, patch) return patch end,
    join = function(_, left, right)
      return { delta = (left and left.delta or 0) + (right and right.delta or 0) }
    end,
    constraint = function(_, patch) return patch end,
    supplies = function() return {} end,
  }
  local fail = {
    name = 'test-fail',
    apply = function() error('deliberate commit calculation failure', 0) end,
    stage = add.stage,
    join = add.join,
    constraint = add.constraint,
    supplies = add.supplies,
  }
  local callback_calls = 0
  local a = Journal.new_location({ algebra = add, value = 10, apply = function() callback_calls = callback_calls + 1 end })
  local b = Journal.new_location({ algebra = add, value = 20 })
  local writes = { [a] = { delta = 1 }, [b] = { delta = 2 } }
  local order = {}
  for location in pairs(writes) do order[#order + 1] = location end
  order[2].algebra = fail

  local ok = pcall(Journal.commit, writes)
  assert(not ok, 'commit calculation failure should escape')
  assert(a.value == 10 and b.value == 20, 'failed calculation partially installed committed values')
  assert(a.version == 0 and b.version == 0, 'failed calculation partially advanced committed versions')
  assert(callback_calls == 0 and a.apply == nil, 'locations must not carry installation callbacks')
end

print('tests/kernel/test_trail_journal.lua: ok')

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
local PQ = require('examples.recipes.priority_queue')
local Runtime = require('fibers.runtime')
local function fail(m)
  error(m, 2)
end
local function eq(a, b, m)
  if a ~= b then
    fail((m or 'not equal') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a))
  end
end
local function found(s)
  eq(s and s.tag, 'found')
end
local q = PQ.new(2, 'q')
local r = Runtime.new()
r:spawn_raw(function()
  r:perform(Op.each({ q:put_op(10, 'low'), q:put_op(1, 'high') }))
end)
found(r:run())
local r2 = Runtime.new()
local a, pa, b, pb
r2:spawn_raw(function()
  a, pa = r2:perform(q:get_op())
  b, pb = r2:perform(q:get_op())
end)
found(r2:run())
eq(a, 'high')
eq(pa, 1)
eq(b, 'low')
eq(pb, 10)
local q2 = PQ.new(math.huge, 'handoff')
local r3 = Runtime.new()
local rows
r3:spawn_raw(function()
  rows = r3:perform(Op.together({ q2:put_op(0, 'urgent'), q2:get_op() }))
end)
found(r3:run())
eq(rows[2][1], 'urgent')
local empty
local r4 = Runtime.new()
r4:spawn_raw(function()
  empty = r4:perform(q2:get_op():or_else(Op.always('empty')))
end)
found(r4:run())
eq(empty, 'empty')
print('examples/recipes/tests/test_priority_queue_composition.lua: ok')

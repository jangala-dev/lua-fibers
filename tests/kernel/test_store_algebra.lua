package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')
local Facility = require('fibers.resource.authoring')
local Extreme = require('fibers.resource.extreme')
local S = require('fibers.internal.kernel.journal')
local A = require('fibers.internal.kernel.algebra')
local Operation = require('fibers.internal.operation')

local function fail(msg)
  error(msg, 2)
end
local function eq(a, b, msg)
  if a ~= b then
    fail((msg or 'not equal') .. ': ' .. tostring(a) .. ' ~= ' .. tostring(b))
  end
end
local function truth(v, msg)
  if not v then
    fail(msg or 'expected true')
  end
end
local function map_eq(a, b, msg)
  for k, v in pairs(a or {}) do
    if b[k] ~= v then
      fail((msg or 'map mismatch') .. ' at ' .. tostring(k))
    end
  end
  for k, v in pairs(b or {}) do
    if a[k] ~= v then
      fail((msg or 'map mismatch') .. ' at ' .. tostring(k))
    end
  end
end

local add = S.new_location({ algebra = 'add', value = 0 })
local a = { kind = 'add', delta = 2 }
local b = { kind = 'add', delta = -1 }
local c = { kind = 'add', delta = 4 }
local ab = A.join(add, a, b, 'independent')
local ba = A.join(add, b, a, 'independent')
eq(ab.delta, ba.delta, 'add parallel composition should commute')
local abc1 = A.join(add, ab, c, 'independent')
local bc = A.join(add, b, c, 'independent')
local abc2 = A.join(add, a, bc, 'independent')
eq(abc1.delta, abc2.delta, 'add parallel composition should associate')
eq(A.constraint(add, a, 'up'), nil, 'upward add is supply for upward claim')
eq(A.constraint(add, b, 'up').delta, -1, 'downward add constrains upward claim')

local fm = S.new_location({ algebra = 'finite_map', value = {}, put_equal = true })
local px = { kind = 'finite_map', ops = { { op = 'put', key = 'x', value = 1 } } }
local py = { kind = 'finite_map', ops = { { op = 'put', key = 'y', value = 2 } } }
local rm = { kind = 'finite_map', ops = { { op = 'remove', key = 'z' } } }
local xy = A.join(fm, px, py, 'independent')
local yx = A.join(fm, py, px, 'independent')
map_eq(A.apply(fm, {}, xy), A.apply(fm, {}, yx), 'disjoint finite-map edits should commute')
local down = A.constraint(fm, {
  kind = 'finite_map',
  ops = {
    { op = 'put', key = 'x', value = 1 },
    { op = 'remove', key = 'z' },
  },
}, 'up')
eq(#down.ops, 1)
eq(down.ops[1].op, 'remove', 'upward claims retain only downward constraints')
local up = A.constraint(fm, {
  kind = 'finite_map',
  ops = {
    { op = 'put', key = 'x', value = 1 },
    { op = 'remove', key = 'z' },
  },
}, 'down')
eq(#up.ops, 1)
eq(up.ops[1].op, 'put', 'downward claims retain only upward constraints')
local hand = A.join(fm, px, { kind = 'finite_map', ops = { { op = 'take', key = 'x' } } }, 'interacting')
eq(next(A.apply(fm, {}, hand)), nil, 'put/take handoff should cancel')

local overwrite = S.new_location({ algebra = 'finite_map', value = {}, put_equal = true })
local p1 = { kind = 'finite_map', ops = { { op = 'put', key = 'x', value = 'a', policy = 'overwrite' } } }
local p2 = { kind = 'finite_map', ops = { { op = 'put', key = 'x', value = 'b', policy = 'overwrite' } } }
local independent = A.join(overwrite, p1, p2, 'independent')
eq(independent, nil, 'independent conflicting overwrites must remain partial')
local interacting = A.join(overwrite, p1, p2, 'interacting')
eq(A.apply(overwrite, {}, interacting).x, 'b', 'interacting overwrite is ordered')

local lazy_writer_location = S.new_location({ algebra = 'replace', value = 0 })
local lazy_journal = S.new()
local lazy_writer_view = lazy_journal:new_segment(1, {}, nil)
S.stage(lazy_writer_view, lazy_writer_location, { kind = 'replace', value = 1 })
assert(next(lazy_journal.writers) == nil, 'ordinary writes should not activate the projection index')

local projection_location = S.new_location({ algebra = 'finite_map', value = {}, put_equal = true })
local roots = { {}, {}, {}, [{}] = true }
local projection_task = { root = roots[3], scope_path = {} }
local projection_journal = S.new()
projection_journal.segments = {
  [2] = {
    id = 2,
    root = roots[2],
    scope_path = {},
    values = {},
    delta = { [projection_location] = p2 },
    retired = false,
    journal = projection_journal,
  },
  [3] = {
    id = 3,
    root = roots[3],
    scope_path = {},
    values = {},
    delta = {},
    retired = false,
    journal = projection_journal,
  },
  [1] = {
    id = 1,
    root = roots[1],
    scope_path = {},
    values = {},
    delta = { [projection_location] = p1 },
    retired = false,
    journal = projection_journal,
  },
  [99] = {
    id = 99,
    root = {},
    scope_path = {},
    values = {},
    delta = setmetatable({}, {
      __index = function()
        error('projection scanned an unrelated segment')
      end,
    }),
    retired = false,
    journal = projection_journal,
  },
}
projection_task.segment = projection_journal.segments[3]
local projected = S.project(projection_task, projection_location)
eq(projected.x, 'b', 'external projection must follow deterministic view order')

local machine = S.new_location({ algebra = 'machine', value = 0 })
local machine_merged = A.join(machine, {
  kind = 'machine',
  steps = { { serial = 1, value = 1 }, { serial = 3, value = 3 } },
}, {
  kind = 'machine',
  steps = { { serial = 2, value = 2 }, { serial = 4, value = 4 } },
}, 'interacting')
for i = 1, 4 do
  eq(machine_merged.steps[i].serial, i, 'machine merge must retain serial order')
end

local extreme_value = {
  a = { rank = 1, seq = 2, value = 'a' },
  b = { rank = 1, seq = 1, value = 'b' },
  c = { rank = 2, seq = 1, value = 'c' },
  d = { rank = 2, seq = 1, value = 'd' },
}
local minimum_leaf = Extreme.spec({
  location = fm,
  order = 'min',
  rank_field = 'rank',
  seq_field = 'seq',
  result = Facility.result.value,
})
local minimum = Operation.transition_cursor(minimum_leaf, extreme_value, {}, nil):next()
eq(minimum.result[1].value, 'b', 'minimum selection order changed')
local maximum_leaf = Extreme.spec({
  location = fm,
  order = 'max',
  rank_field = 'rank',
  seq_field = 'seq',
  result = Facility.result.value,
})
local maximum = Operation.transition_cursor(maximum_leaf, extreme_value, {}, nil):next()
eq(maximum.result[1].value, 'd', 'maximum selection order changed')

print('tests/test_store_algebra.lua: ok')

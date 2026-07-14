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
local S = require('fibers.internal.kernel.store')

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

local add = S.new_location({ merge = 'add', value = 0 })
local a = { kind = 'add', delta = 2 }
local b = { kind = 'add', delta = -1 }
local c = { kind = 'add', delta = 4 }
local ab = S.merge_parallel(add, a, b, 'independent')
local ba = S.merge_parallel(add, b, a, 'independent')
eq(ab.delta, ba.delta, 'add parallel composition should commute')
local abc1 = S.merge_parallel(add, ab, c, 'independent')
local bc = S.merge_parallel(add, b, c, 'independent')
local abc2 = S.merge_parallel(add, a, bc, 'independent')
eq(abc1.delta, abc2.delta, 'add parallel composition should associate')
eq(S.constraint_projection(add, a, 'up'), nil, 'upward add is supply for upward claim')
eq(S.constraint_projection(add, b, 'up').delta, -1, 'downward add constrains upward claim')

local fm = S.new_location({ merge = 'finite_map', value = {}, put_equal = true })
local px = { kind = 'finite_map', ops = { { op = 'put', key = 'x', value = 1 } } }
local py = { kind = 'finite_map', ops = { { op = 'put', key = 'y', value = 2 } } }
local rm = { kind = 'finite_map', ops = { { op = 'remove', key = 'z' } } }
local xy = S.merge_parallel(fm, px, py, 'independent')
local yx = S.merge_parallel(fm, py, px, 'independent')
map_eq(
  S.apply_patch_value(fm, {}, xy),
  S.apply_patch_value(fm, {}, yx),
  'disjoint finite-map edits should commute'
)
local down = S.constraint_projection(fm, {
  kind = 'finite_map',
  ops = {
    { op = 'put', key = 'x', value = 1 },
    { op = 'remove', key = 'z' },
  },
}, 'up')
eq(#down.ops, 1)
eq(down.ops[1].op, 'remove', 'upward claims retain only downward constraints')
local up = S.constraint_projection(fm, {
  kind = 'finite_map',
  ops = {
    { op = 'put', key = 'x', value = 1 },
    { op = 'remove', key = 'z' },
  },
}, 'down')
eq(#up.ops, 1)
eq(up.ops[1].op, 'put', 'downward claims retain only upward constraints')
local hand =
  S.merge_parallel(fm, px, { kind = 'finite_map', ops = { { op = 'take', key = 'x' } } }, 'interacting')
eq(next(S.apply_patch_value(fm, {}, hand)), nil, 'put/take handoff should cancel')

local overwrite = S.new_location({ merge = 'finite_map', value = {}, put_equal = true })
local p1 = { kind = 'finite_map', ops = { { op = 'put', key = 'x', value = 'a', policy = 'overwrite' } } }
local p2 = { kind = 'finite_map', ops = { { op = 'put', key = 'x', value = 'b', policy = 'overwrite' } } }
local independent = S.merge_parallel(overwrite, p1, p2, 'independent')
eq(independent, nil, 'independent conflicting overwrites must remain partial')
local interacting = S.merge_parallel(overwrite, p1, p2, 'interacting')
eq(S.apply_patch_value(overwrite, {}, interacting).x, 'b', 'interacting overwrite is ordered')

print('tests/test_store_algebra.lua: ok')

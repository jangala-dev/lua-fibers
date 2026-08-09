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
local Algebra = require('fibers.internal.kernel.algebra')

local function fail(message)
  error(message, 2)
end
local function eq(actual, expected, message)
  if actual ~= expected then
    fail((message or 'values differ') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual))
  end
end
local function truth(value, message)
  if not value then
    fail(message or 'expected true')
  end
end

local function location(merge, value)
  return Journal.new_location({ algebra = merge, value = value })
end

local trail = Journal.new()
local segment = trail:new_segment(1)

local replace = location('replace', 1)
local mark = trail:mark()
Journal.stage(segment, replace, { kind = 'replace', value = 2 })
eq(Journal.read(segment, replace), 2, 'replace should be visible before rollback')
truth(segment.delta[replace], 'replace patch should be staged')
trail:rollback(mark)
eq(segment.values[replace], nil, 'inserted replace observation should be removed')
eq(segment.delta[replace], nil, 'replace patch should be removed')

local add = location('add', 10)
Journal.stage(segment, add, { kind = 'add', delta = 2 })
mark = trail:mark()
Journal.stage(segment, add, { kind = 'add', delta = 3 })
eq(Journal.read(segment, add), 15, 'add should accumulate before rollback')
eq(segment.delta[add].delta, 5, 'add patch should accumulate before rollback')
trail:rollback(mark)
eq(Journal.read(segment, add), 12, 'add cell should restore')
eq(segment.delta[add].delta, 2, 'add patch should restore')

local presence = location('presence', Algebra.ABSENT)
Journal.stage(segment, presence, { kind = 'presence', ops = { { op = 'put', value = 'a' } } })
mark = trail:mark()
Journal.stage(segment, presence, { kind = 'presence', ops = { { op = 'remove' } } })
eq(#segment.delta[presence].ops, 2, 'presence operation should append')
trail:rollback(mark)
eq(#segment.delta[presence].ops, 1, 'presence operation append should roll back')
eq(Journal.read(segment, presence), 'a', 'presence value should restore')

local finite = location('finite_map', {})
Journal.stage(segment, finite, { kind = 'finite_map', ops = { { op = 'put', key = 'a', value = 1 } } })
mark = trail:mark()
Journal.stage(segment, finite, { kind = 'finite_map', ops = { { op = 'put', key = 'b', value = 2 } } })
eq(#segment.delta[finite].ops, 2, 'finite-map operation should append')
trail:rollback(mark)
eq(#segment.delta[finite].ops, 1, 'finite-map append should roll back')
eq(Journal.read(segment, finite).b, nil, 'finite-map value should restore')

local machine = location('machine', 'zero')
Journal.stage(segment, machine, { kind = 'machine', steps = { { serial = 1, value = 'one' } } })
mark = trail:mark()
Journal.stage(segment, machine, { kind = 'machine', steps = { { serial = 2, value = 'two' } } })
eq(#segment.delta[machine].steps, 2, 'machine step should append')
trail:rollback(mark)
eq(#segment.delta[machine].steps, 1, 'machine step append should roll back')
eq(Journal.read(segment, machine), 'one', 'machine value should restore')

local parent = trail:new_segment(1)
local child = trail:new_segment(1, parent)
local observed = location('replace', 'committed')
Journal.read(child, observed)
mark = trail:mark()
truth(Journal.join_segments(parent, { child }, 'independent'), 'segment join should succeed')
eq(trail.observed[observed], observed.version, 'child observation should remain proof-wide')
trail:rollback(mark)
eq(trail.observed[observed], observed.version, 'pre-mark observation should survive rollback')
eq(child.retired, false, 'merged flag should roll back')

print('tests/test_store_rollback.lua: ok')

local inherited_loc = location('replace', 'base')
local root = trail:new_segment(1)
Journal.read(root, inherited_loc)
local lane = trail:new_segment(1, root, { mode = 'independent' }, 1)
eq(next(lane.values), nil, 'lane creation should not copy parent observations')
eq(Journal.read(lane, inherited_loc), 'base', 'lane should read inherited observation')
eq(lane.values[inherited_loc], nil, 'inherited read should remain sparse')

mark = trail:mark()
Journal.stage(lane, inherited_loc, { kind = 'replace', value = 'lane' })
eq(Journal.read(lane, inherited_loc), 'lane', 'lane write should be locally visible')
eq(Journal.read(root, inherited_loc), 'base', 'lane write must not mutate parent')
truth(lane.values[inherited_loc], 'lane write should promote one local cell')
trail:rollback(mark)
eq(lane.values[inherited_loc], nil, 'lane copy-on-write cell should roll back')
eq(Journal.read(lane, inherited_loc), 'base', 'lane should resume inherited value after rollback')

local nested = trail:new_segment(1, lane, { mode = 'independent' }, 1)
eq(Journal.read(nested, inherited_loc), 'base', 'nested lane should walk the parent chain')
eq(next(nested.values), nil, 'nested inherited read should remain sparse')

local fresh_loc = location('replace', 'fresh')
Journal.read(nested, fresh_loc)
eq(nested.values[fresh_loc], nil, 'read-only observations should not allocate segment values')
eq(trail.observed[fresh_loc], fresh_loc.version, 'first observation should be proof-wide')
truth(Journal.join_segments(lane, { nested }, 'independent'), 'nested sparse merge should succeed')
eq(lane.values[fresh_loc], nil, 'joining should not materialise read-only values')
truth(Journal.join_segments(root, { lane }, 'independent'), 'outer sparse merge should succeed')
eq(trail.observed[fresh_loc], fresh_loc.version, 'proof-wide observation should survive joins')

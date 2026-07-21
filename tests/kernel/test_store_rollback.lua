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

local Store = require('fibers.internal.kernel.ledger')
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

local Trail = {}
Trail.__index = Trail
function Trail.new()
  return setmetatable({ entries = {} }, Trail)
end
function Trail:mark()
  return #self.entries
end
function Trail:set(target, key, value)
  if target[key] == value then
    return
  end
  self.entries[#self.entries + 1] = { kind = 'set', target = target, key = key, old = target[key] }
  target[key] = value
end
function Trail:push(target, value)
  self.entries[#self.entries + 1] = { kind = 'push', target = target, old = #target }
  target[#target + 1] = value
end
function Trail:rollback(mark)
  for i = #self.entries, mark + 1, -1 do
    local entry = self.entries[i]
    if entry.kind == 'set' then
      entry.target[entry.key] = entry.old
    else
      for j = #entry.target, entry.old + 1, -1 do
        entry.target[j] = nil
      end
    end
    self.entries[i] = nil
  end
end

local function location(merge, value)
  return Store.new_location({ algebra = merge, value = value })
end

local trail = Trail.new()
local segment = Store.new_segment(1, {})

local replace = location('replace', 1)
local mark = trail:mark()
Store.stage(segment, replace, { kind = 'replace', value = 2 }, trail)
eq(Store.read(segment, replace), 2, 'replace should be visible before rollback')
truth(segment.delta[replace], 'replace patch should be staged')
trail:rollback(mark)
eq(segment.values[replace], nil, 'inserted replace observation should be removed')
eq(segment.delta[replace], nil, 'replace patch should be removed')

local add = location('add', 10)
Store.stage(segment, add, { kind = 'add', delta = 2 }, trail)
mark = trail:mark()
Store.stage(segment, add, { kind = 'add', delta = 3 }, trail)
eq(Store.read(segment, add), 15, 'add should accumulate before rollback')
eq(segment.delta[add].delta, 5, 'add patch should accumulate before rollback')
trail:rollback(mark)
eq(Store.read(segment, add), 12, 'add cell should restore')
eq(segment.delta[add].delta, 2, 'add patch should restore')

local presence = location('presence', Algebra.ABSENT)
Store.stage(segment, presence, { kind = 'presence', ops = { { op = 'put', value = 'a' } } }, trail)
mark = trail:mark()
Store.stage(segment, presence, { kind = 'presence', ops = { { op = 'remove' } } }, trail)
eq(#segment.delta[presence].ops, 2, 'presence operation should append')
trail:rollback(mark)
eq(#segment.delta[presence].ops, 1, 'presence operation append should roll back')
eq(Store.read(segment, presence), 'a', 'presence value should restore')

local finite = location('finite_map', {})
Store.stage(segment, finite, { kind = 'finite_map', ops = { { op = 'put', key = 'a', value = 1 } } }, trail)
mark = trail:mark()
Store.stage(segment, finite, { kind = 'finite_map', ops = { { op = 'put', key = 'b', value = 2 } } }, trail)
eq(#segment.delta[finite].ops, 2, 'finite-map operation should append')
trail:rollback(mark)
eq(#segment.delta[finite].ops, 1, 'finite-map append should roll back')
eq(Store.read(segment, finite).b, nil, 'finite-map value should restore')

local machine = location('machine', 'zero')
Store.stage(segment, machine, { kind = 'machine', steps = { { serial = 1, value = 'one' } } }, trail)
mark = trail:mark()
Store.stage(segment, machine, { kind = 'machine', steps = { { serial = 2, value = 'two' } } }, trail)
eq(#segment.delta[machine].steps, 2, 'machine step should append')
trail:rollback(mark)
eq(#segment.delta[machine].steps, 1, 'machine step append should roll back')
eq(Store.read(segment, machine), 'one', 'machine value should restore')

local parent = Store.new_segment(1, {})
local child = Store.new_segment(1, {}, parent)
local observed = location('replace', 'committed')
Store.read(child, observed)
mark = trail:mark()
truth(Store.join_segments(parent, { child }, 'independent', trail), 'segment join should succeed')
eq(parent.ledger.observed[observed], observed.version, 'child observation should remain proof-wide')
trail:rollback(mark)
eq(parent.ledger.observed[observed], observed.version, 'pre-mark observation should survive rollback')
eq(child.retired, false, 'merged flag should roll back')

print('tests/test_store_rollback.lua: ok')

local inherited_loc = location('replace', 'base')
local root = Store.new_segment(1, {}, nil, 1)
Store.read(root, inherited_loc)
local lane = Store.new_segment(1, { { group_id = 1, mode = 'independent', lane = 1 } }, root, 2)
eq(next(lane.values), nil, 'lane creation should not copy parent observations')
eq(Store.read(lane, inherited_loc), 'base', 'lane should read inherited observation')
eq(lane.values[inherited_loc], nil, 'inherited read should remain sparse')

mark = trail:mark()
Store.stage(lane, inherited_loc, { kind = 'replace', value = 'lane' }, trail)
eq(Store.read(lane, inherited_loc), 'lane', 'lane write should be locally visible')
eq(Store.read(root, inherited_loc), 'base', 'lane write must not mutate parent')
truth(lane.values[inherited_loc], 'lane write should promote one local cell')
trail:rollback(mark)
eq(lane.values[inherited_loc], nil, 'lane copy-on-write cell should roll back')
eq(Store.read(lane, inherited_loc), 'base', 'lane should resume inherited value after rollback')

local nested = Store.new_segment(1, { { group_id = 2, mode = 'independent', lane = 1 } }, lane, 3)
eq(Store.read(nested, inherited_loc), 'base', 'nested lane should walk the parent chain')
eq(next(nested.values), nil, 'nested inherited read should remain sparse')

local fresh_loc = location('replace', 'fresh')
Store.read(nested, fresh_loc)
eq(nested.values[fresh_loc], nil, 'read-only observations should not allocate segment values')
eq(nested.ledger.observed[fresh_loc], fresh_loc.version, 'first observation should be proof-wide')
truth(Store.join_segments(lane, { nested }, 'independent', trail), 'nested sparse merge should succeed')
eq(lane.values[fresh_loc], nil, 'joining should not materialise read-only values')
truth(Store.join_segments(root, { lane }, 'independent', trail), 'outer sparse merge should succeed')
eq(root.ledger.observed[fresh_loc], fresh_loc.version, 'proof-wide observation should survive joins')

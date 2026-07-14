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
local FibersIndex = require('fibers.resource.index')
local FibersRegion = require('fibers.lifetime.region')
local FibersTask = require('fibers.task')
local TC = require('tests.support.effect_helpers')

local function fail(msg)
  error(msg, 2)
end
local function assert_eq(a, b, msg)
  if a ~= b then
    fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a))
  end
end
local function assert_truthy(v, msg)
  if not v then
    fail(msg or 'expected truthy')
  end
end
local function assert_status(st, tag, msg)
  if not st or st.tag ~= tag then
    fail((msg or 'status mismatch') .. ': expected ' .. tostring(tag) .. ', got ' .. tostring(st and st.tag))
  end
end

local Op = FibersOp
local Index = FibersIndex
local Region = FibersRegion
local Task = FibersTask

-- Region operations should compose after a witnessed Index selection.  The item is
-- inserted into the index and consumed by a same-world pop; the continuation then
-- admits the concrete selected value into the region.
do
  local ix = Index.new(nil, 'region-frame-index')
  local region = Region.new('region-frame-region')
  local item = Region.handle('region-frame-item')
  local rows

  local st = fibers.try_run(function()
    rows = fibers.perform(Op.tensor({
      ix:insert_op('item', 0, item),
      ix:pop_first_op():and_then(function(entry)
        return region:admit_op(Region.Owned.inert(entry.value))
      end),
    }))
  end).runtime_status

  assert_status(st, 'found')
  assert_eq(rows[2][1], item, 'region admit should receive the concrete selected item')
  assert_eq(item.owner, region, 'selected item should be owned by region after commit')
  assert_truthy(region.owned[item], 'region ledger should contain selected item')
end

-- Effects emitted after a witnessed selection should see concrete committed payloads and
-- discharge once after commit.
do
  local ix = Index.new(nil, 'effect-frame-index')
  local calls = {}
  local rows

  local st = fibers.try_run(function()
    rows = fibers.perform(Op.tensor({
      ix:insert_op('k', 0, 'payload'),
      ix:pop_first_op():and_then(function(entry)
        return Op.emit(TC.tag('effect-frame', { value = entry.value })):map(function()
          return entry.key, entry.value
        end)
      end),
    }))
  end, {
    host = {
      test_tag = function(_tag, payload)
        calls[#calls + 1] = payload.value
      end,
    },
  }).runtime_status

  assert_status(st, 'found')
  assert_eq(rows[2][1], 'k')
  assert_eq(rows[2][2], 'payload')
  assert_eq(#calls, 1, 'effect should discharge once')
  assert_eq(calls[1], 'payload', 'effect payload should be the concrete selected value')
end

-- Task spawn should remain a post-commit effect when it follows a witnessed selection.
-- The child receives the concrete selected value via ordinary Lua capture.
do
  local ix = Index.new(nil, 'task-frame-index')
  local region = Region.new('task-frame-region')
  local task, value, rows

  local st = fibers.try_run(function()
    rows = fibers.perform(Op.tensor({
      ix:insert_op('k', 0, 'task-value'),
      ix:pop_first_op():and_then(function(entry)
        return Task.spawn_op(region, function()
          return entry.value
        end, 'task-frame-child')
      end),
    }))
    task = rows[2][1]
    value = fibers.perform(task:await_op())
  end).runtime_status

  assert_status(st, 'found')
  assert_truthy(task, 'task handle should be returned')
  assert_eq(task.owner, region, 'task should be admitted to region')
  assert_eq(value, 'task-value', 'task should observe concrete selected value')
end

print('tests/test_region_task_effects.lua: ok')

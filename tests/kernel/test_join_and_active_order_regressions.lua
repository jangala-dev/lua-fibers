package.path = table.concat({
  './src/?.lua', './src/?/init.lua', './src/?/?.lua',
  './?.lua', './?/init.lua', './?/?.lua', package.path,
}, ';')

local Op = require('fibers.op')
local Counter = require('fibers.resource.counter')
local Runtime = require('fibers.runtime')
local Journal = require('fibers.internal.kernel.journal')

local function eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'values differ') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual), 2)
  end
end

local function perform(build)
  local rt, result = Runtime.new({ choice_seed = 1 }), nil
  rt:spawn_raw(function() result = rt:perform(build()) end, 'regression-root')
  eq(rt:run().tag, 'found')
  return result
end

-- Joining a materialised child into an unmaterialised parent applies its delta once.
do
  local location = Journal.new_location({ algebra = 'add', value = 5, name = 'join-once' })
  local journal = Journal.new()
  local parent = journal:new_segment(1, {}, nil)
  local child = journal:new_segment(1, { { group_id = 1, mode = 'independent', lane = 1 } }, parent)
  Journal.stage(child, location, { kind = 'add', delta = -2 })
  eq(Journal.read(child, location), 3)
  eq(Journal.join_segments(parent, { child }, 'independent'), true)
  eq(Journal.read(parent, location), 3)
  eq(parent.delta[location].delta, -2)
end

-- The public evaluator preserves the same invariant across and_then.
do
  local counter = Counter.new(5, 'join-continuation')
  local result = perform(function()
    return Op.each({ counter:take_op(2), counter:read_op() }):and_then(counter:read_op())
  end)
  eq(result, 3)
  eq(counter.value, 3)
end

local function observed_with(mode, lane_order, sibling_kind)
  local counter = Counter.new(5, table.concat({ 'active-order', mode, lane_order, sibling_kind }, '-'))
  local take, observe = counter:take_op(1), counter:at_least_op(1)
  local inner = Op.each(lane_order == 'take-observe' and { take, observe } or { observe, take })
  local sibling
  if sibling_kind == 'plain' then
    sibling = Op.always(2)
  elseif sibling_kind == 'preferred' then
    sibling = Op.always(2):or_else(counter:at_least_op(3))
  elseif sibling_kind == 'fallback' then
    sibling = Op.never():or_else(Op.always(2))
  else
    sibling = Op.always(2):or_else(Op.never()):or_else(counter:at_least_op(3))
  end
  local rows = perform(function() return (mode == 'together' and Op.together or Op.each)({ inner, sibling }) end)
  local inner_rows = rows[1][1]
  local observed_row = inner_rows[lane_order == 'take-observe' and 2 or 1]
  return observed_row[1], counter.value
end

for _, mode in ipairs({ 'each', 'together' }) do
  for _, lane_order in ipairs({ 'take-observe', 'observe-take' }) do
    local baseline, baseline_value = observed_with(mode, lane_order, 'plain')
    for _, sibling_kind in ipairs({ 'preferred', 'fallback', 'nested' }) do
      local observed, value = observed_with(mode, lane_order, sibling_kind)
      eq(observed, baseline, table.concat({ mode, lane_order, sibling_kind }, ': '))
      eq(value, baseline_value)
    end
  end
end

print('tests/kernel/test_join_and_active_order_regressions.lua: ok')

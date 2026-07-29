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

local Op = require('fibers.op')
local Counter = require('fibers.resource.counter')
local Runtime = require('fibers.runtime')
local ReferenceStore = require('fibers.internal.reference_store')

local function fail(message)
  error(message, 2)
end

local function eq(actual, expected, message)
  if actual ~= expected then
    fail((message or 'values differ') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual))
  end
end

local function run(machine, build)
  local runtime = Runtime.new({ machine = machine, choice_seed = 1 })
  local result
  runtime:spawn_raw(function()
    result = runtime:perform(build())
  end, 'regression-root')
  local status = runtime:run()
  eq(status and status.tag, 'found', machine .. ': operation should commit')
  return result
end

-- A child segment's materialised value already includes child.delta. Joining it
-- into an unmaterialised parent must therefore preserve the common base
-- observation and stage the child delta exactly once.
do
  local location = ReferenceStore.new_location({ algebra = 'add', value = 5, name = 'join-once' })
  local parent = ReferenceStore.new_segment(1, {}, nil, 1)
  local child = ReferenceStore.new_segment(1, { { group_id = 1, mode = 'independent', lane = 1 } }, parent, 2)
  ReferenceStore.stage(child, location, { kind = 'add', delta = -2 })
  eq(ReferenceStore.read(child, location), 3, 'child should contain its staged value')
  eq(ReferenceStore.join_segments(parent, { child }, 'independent'), true, 'join should succeed')
  eq(ReferenceStore.read(parent, location), 3, 'join must apply the child delta once')
  eq(parent.delta[location].delta, -2, 'joined summary must contain one child delta')
end

-- The same invariant must survive the public evaluator boundary and an
-- and_then continuation which reads the joined product state.
for _, machine in ipairs({ 'ledger', 'reference' }) do
  local counter = Counter.new(5, 'join-continuation-' .. machine)
  local result = run(machine, function()
    return Op.each({ counter:take_op(2), counter:read_op() }):and_then(function()
      return counter:read_op()
    end)
  end)
  eq(result, 3, machine .. ': continuation should see one merged decrement')
  eq(counter.value, 3, machine .. ': committed counter should match continuation')
end

local function observed_with(machine, mode, lane_order, sibling_kind)
  local counter =
    Counter.new(5, table.concat({ 'active-order', machine, mode, lane_order, sibling_kind }, '-'))
  local take = counter:take_op(1)
  local observe = counter:at_least_op(1)
  local inner = Op.each(lane_order == 'take-observe' and { take, observe } or { observe, take })

  local sibling
  if sibling_kind == 'plain' then
    sibling = Op.always(2)
  elseif sibling_kind == 'preferred' then
    sibling = Op.always(2):or_else(counter:at_least_op(3))
  elseif sibling_kind == 'fallback' then
    sibling = Op.never():or_else(Op.always(2))
  elseif sibling_kind == 'nested' then
    sibling = Op.always(2):or_else(Op.never()):or_else(counter:at_least_op(3))
  else
    error('unknown sibling kind', 0)
  end

  local outer = (mode == 'together' and Op.together or Op.each)({ inner, sibling })
  local rows = run(machine, function()
    return outer
  end)
  local inner_rows = rows[1][1]
  local observed_row = inner_rows[lane_order == 'take-observe' and 2 or 1]
  return observed_row[1], counter.value
end

-- Entering an or_else preferred arm or fallback may put that task at the front
-- of the active worklist, but it must not reverse the order of unrelated tasks
-- which were already queued. A dormant or immediately certified or_else is
-- observationally transparent to neighbouring product lanes.
for _, machine in ipairs({ 'ledger', 'reference' }) do
  for _, mode in ipairs({ 'each', 'together' }) do
    for _, lane_order in ipairs({ 'take-observe', 'observe-take' }) do
      local baseline, baseline_value = observed_with(machine, mode, lane_order, 'plain')
      for _, sibling_kind in ipairs({ 'preferred', 'fallback', 'nested' }) do
        local observed, value = observed_with(machine, mode, lane_order, sibling_kind)
        eq(
          observed,
          baseline,
          table.concat({ machine, mode, lane_order, sibling_kind, 'must preserve sibling observation' }, ': ')
        )
        eq(value, baseline_value, machine .. ': committed value must remain unchanged')
      end
    end
  end
end

print('tests/kernel/test_join_and_active_order_regressions.lua: ok')

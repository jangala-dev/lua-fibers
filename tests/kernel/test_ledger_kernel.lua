local Runtime = require('fibers.runtime')
local Store = require('fibers.internal.kernel.ledger')
local Ledger = require('fibers.internal.kernel.ledger')
local Path = require('fibers.internal.kernel.path')
local Trail = require('fibers.internal.kernel.trail')

local function eq(actual, expected, message)
  if actual ~= expected then
    error(
      (message or 'values differ') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual),
      2
    )
  end
end

local function truthy(value, message)
  if not value then
    error(message or 'expected truthy value', 2)
  end
end

local runtime = Runtime.new({ machine = 'ledger' })
eq(runtime.machine_name, 'ledger', 'ledger machine selection')

local state = {
  segments = {},
}
Ledger.begin_state(state)
state.trail = Trail.new({}, nil)
state.trail.on_rollback = Ledger.invalidate
state.trail.rollback_context = state

local counter = Store.new_location({
  name = 'ledger-test-counter',
  algebra = 'add',
  value = 0,
})

local root = Ledger.new_segment(1, nil, nil, 1, {}, state)
state.segments[1] = root

eq(Ledger.read(root, counter, state.trail), 0, 'initial ledger read')
eq(next(root.values), nil, 'a ledger read allocated a speculative cell')
eq(state.ledger.observed[counter], 0, 'ledger did not record the committed version')

local lane1_path = Path.scope_child(nil, 1, 'independent', 1)
local lane2_path = Path.scope_child(nil, 1, 'independent', 2)
local lane1 = Ledger.new_segment(1, lane1_path, root, 2, {}, state)
local lane2 = Ledger.new_segment(1, lane2_path, root, 3, {}, state)
state.segments[2], state.segments[3] = lane1, lane2

Ledger.stage(lane1, counter, { kind = 'add', delta = 5 }, state.trail)
Ledger.stage(lane2, counter, { kind = 'add', delta = -2 }, state.trail)
local task2 = { segment_id = 3, root_id = 1, scope_path = lane2_path }

eq(
  Ledger.project(state, task2, counter, 'up', state.trail),
  -2,
  'independent positive supply should be hidden'
)
eq(
  Ledger.project(state, task2, counter, 'down', state.trail),
  3,
  'independent constraining supply should remain visible'
)

truthy(Ledger.join_segments(root, { lane1, lane2 }, 'independent', state.trail))
eq(Ledger.read(root, counter, state.trail), 3, 'product summaries did not join into the parent')
Ledger.project(state, { segment_id = 1, root_id = 1, scope_path = nil }, counter, 'up', state.trail)
local bucket = state.ledger.writers[counter]
eq(#bucket.list, 1, 'retired lanes remained in the rebuilt writer frontier')
eq(bucket.list[1], root, 'parent segment was not the remaining location writer')
eq(lane1.retired, true, 'retired lane was not marked merged')
eq(lane2.retired, true, 'retired lane was not marked merged')

local rollback_location = Store.new_location({
  name = 'ledger-test-rollback',
  algebra = 'add',
  value = 10,
})
local mark = state.trail:mark()
Ledger.stage(root, rollback_location, { kind = 'add', delta = 1 }, state.trail)
eq(state.ledger.writers[rollback_location], nil, 'a write eagerly created a writer frontier')
local rollback_task = { segment_id = 1, root_id = 1, scope_path = nil }
eq(Ledger.project(state, rollback_task, rollback_location, 'up', state.trail), 11)
truthy(state.ledger.writers[rollback_location], 'projection did not construct the writer frontier')
state.trail:rollback(mark)
eq(root.delta[rollback_location], nil, 'rollback retained a staged summary')
eq(state.ledger.writers[rollback_location], nil, 'rollback did not invalidate derived writer frontiers')
Ledger.project(state, rollback_task, rollback_location, 'up', state.trail)
truthy(state.ledger.writers[rollback_location], 'projection did not rebuild an invalid frontier')

local Domain = require('fibers.internal.kernel.domain')
local channel = {}
local domain_state = {
  runtime = { certified_symmetry = false },
  intents = {
    { id = 1, kind = 'exchange', resource = channel, role = 'put' },
    { id = 2, kind = 'exchange', resource = channel, role = 'get' },
    { id = 3, kind = 'exchange', resource = channel, role = 'get' },
  },
}
local demand_index = Domain.new(domain_state.runtime)
for i = 1, #domain_state.intents do
  Domain.add(demand_index, domain_state.intents[i])
end
local domain = Domain.open(demand_index, domain_state, function()
  return true
end, true)
eq(domain.exchange.compatible, 2, 'domain compatibility count')
eq(domain.exchange.pairs, nil, 'lazy domain should not materialise exchange pairs')
local cursor = Domain.cursor(domain)
local first = Domain.next(cursor, {
  witness_cursor = function()
    error('unexpected witness')
  end,
  supplier = function() end,
})
local second = Domain.next(cursor, {
  witness_cursor = function()
    error('unexpected witness')
  end,
  supplier = function() end,
})
eq(first.pair.left, 2, 'most-constrained exchange should lead')
eq(first.pair.right, 1, 'first lazy exchange partner')
eq(second, nil, 'constrained cursor should enumerate only the selected domain')

local small_domain = Domain.open(nil, domain_state, function()
  return true
end, true)
eq(small_domain.exchange.compatible, 2, 'small demand domain compatibility count')
local small_cursor = Domain.cursor(small_domain)
local small_first = Domain.next(small_cursor, {
  witness_cursor = function()
    error('unexpected witness')
  end,
  supplier = function() end,
})
eq(small_first.pair.left, 2, 'small demand domain should retain constrained ordering')
eq(small_first.pair.right, 1, 'small demand domain should expose a compatible partner')

local demand_trail = Trail.new()
local rollback_index = Domain.new(domain_state.runtime)
local demand_mark = demand_trail:mark()
Domain.add(rollback_index, domain_state.intents[1], demand_trail)
Domain.add(rollback_index, domain_state.intents[2], demand_trail)
eq(
  Domain.open(rollback_index, domain_state, function()
    return true
  end, true).exchange.compatible,
  1,
  'incremental demand index did not register blocked intents'
)
demand_trail:rollback(demand_mark)
eq(
  Domain.open(rollback_index, domain_state, function()
    return true
  end, true).exchange.compatible,
  0,
  'rollback retained blocked-demand membership'
)

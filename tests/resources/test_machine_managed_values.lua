package.path = table.concat({
  './src/?.lua', './src/?/init.lua', './src/?/?.lua', './?.lua', './?/init.lua', './?/?.lua', package.path,
}, ';')

local Machine = require('fibers.resource.machine')
local Cell = require('fibers.resource.cell')
local Op = require('fibers.op')
local Runtime = require('fibers.runtime')

local Ready = Machine.Ready

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'values differ') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual), 2)
  end
end

local function perform_one(op)
  local rt, result = Runtime.new()
  rt:spawn_raw(function() result = rt:perform(op) end)
  local status = rt:run()
  assert_eq(status.tag, 'found')
  return result
end

local function rejects(fn, needle)
  local ok, err = pcall(fn)
  assert_eq(ok, false, 'operation unexpectedly succeeded')
  if not tostring(err):find(needle, 1, true) then
    error('expected error containing ' .. needle .. ', got:\n' .. tostring(err), 2)
  end
end

local function test_constructor_and_reads_are_snapshots()
  local source = { count = 1, nested = { flag = true } }
  local machine = Machine.new(source)
  source.nested.flag = false
  local first = perform_one(machine:read_op())
  assert_eq(first.nested.flag, true)
  first.count = 80
  assert_eq(perform_one(machine:read_op()).count, 1)
  assert_eq(machine._location.version, 0)
end

local function test_callbacks_receive_isolated_working_values()
  local mutate_query = Machine.query('managed.query-mutation', function(state)
    state.nested.count = 50
    return Ready.same(state.nested.count)
  end)
  local mutate_update = Machine.update('managed.in-place-update', function(state, payload)
    state.nested.count = state.nested.count + payload.delta
    return Ready.write(state, state.nested.count)
  end)

  local machine = Machine.new({ nested = { count = 1 } })
  assert_eq(perform_one(machine:transition_op(mutate_query)), 50)
  assert_eq(perform_one(machine:read_op()).nested.count, 1, 'query mutation escaped')
  assert_eq(machine._location.version, 0)

  local payload = { delta = 4 }
  local op = machine:transition_op(mutate_update, payload)
  payload.delta = 100
  assert_eq(perform_one(op), 5, 'transition payload was not captured')
  assert_eq(perform_one(machine:read_op()).nested.count, 5)
end

local function test_write_op_captures_value_at_construction()
  local machine = Machine.new({ count = 0 })
  local successor = { count = 7 }
  local write = machine:write_op(successor)
  successor.count = 11
  assert_eq(perform_one(write), true)
  assert_eq(perform_one(machine:read_op()).count, 7)
end

local function test_failed_preferred_transition_rolls_back_working_mutation()
  local machine = Machine.new({ nested = { count = 1 } })
  local gate = Cell.new('closed')
  local mutate = Machine.update('managed.rollback-mutation', function(state)
    state.nested.count = 99
    return Ready.write(state, true)
  end)

  local preferred = machine:transition_op(mutate)
    :and_then(gate:expect_op('open'))
    :and_then(Op.always('primary'))
  local decision = preferred:or_else(machine:read_op())
  local observed = perform_one(decision)

  assert_eq(observed.nested.count, 1, 'failed preferred branch leaked a speculative mutation')
  assert_eq(perform_one(machine:read_op()).nested.count, 1)
  assert_eq(machine._location.version, 0)
end

local function test_invalid_machine_values_fail_loudly()
  rejects(function() Machine.new({ callback = function() end }) end, 'forbidden function value')

  local machine = Machine.new({ count = 0 })
  local transition = Machine.update('managed.invalid-successor', function(state)
    state.bad = function() end
    return Ready.write(state)
  end)
  local rt = Runtime.new()
  rt:spawn_raw(function() rt:perform(machine:transition_op(transition)) end)
  rejects(function() rt:run() end, "Machine transition 'managed.invalid-successor' successor")

  local payload_transition = Machine.query('managed.payload', function()
    return Ready.same(true)
  end)
  rejects(function()
    machine:transition_op(payload_transition, { bad = coroutine.create(function() end) })
  end, 'forbidden thread value')
end

local tests = {
  test_failed_preferred_transition_rolls_back_working_mutation,
  test_constructor_and_reads_are_snapshots,
  test_callbacks_receive_isolated_working_values,
  test_write_op_captures_value_at_construction,
  test_invalid_machine_values_fail_loudly,
}

for i = 1, #tests do tests[i]() end
print('tests/resources/test_machine_managed_values.lua: ok')

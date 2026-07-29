-- Machine-backed Flow built over typed transitions.

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
local StateMachine = require('fibers.resource.machine')
local FibersFlow = require('fibers.resource.flow')
local Op = FibersOp
local Flow = FibersFlow
local FlowErrors = require('fibers.resource.flow.errors')
local Runtime = require('fibers.runtime')
local Inspect = require('tests.support.flow_inspect')

local function fail(msg)
  error(msg, 2)
end
local function assert_eq(actual, expected, msg)
  if actual ~= expected then
    fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual))
  end
end
local function assert_status(st, tag, msg)
  if not st or st.tag ~= tag then
    fail((msg or 'status mismatch') .. ': expected ' .. tostring(tag) .. ', got ' .. tostring(st and st.tag))
  end
end
local function new_runtime(opts)
  return Runtime.new(opts or {})
end

local function test_cell_select_tensor_supply_but_all_non_handoff()
  local supply = StateMachine.update('test.cell.supply', function(v)
    return StateMachine.Ready.write(v + 1, true)
  end)
  local take = StateMachine.select('test.cell.take', function(v)
    if v <= 0 then
      return StateMachine.Wait
    end
    return StateMachine.Ready.write(v - 1, v)
  end)
  local s = StateMachine.new(0, 'select-law')
  local rt = new_runtime()
  local rows
  rt:spawn_raw(function()
    rows = rt:perform(Op.tensor({
      s:transition_op(supply),
      s:transition_op(take),
    }))
  end, 'root')
  assert_status(rt:run(), 'found')
  assert_eq(rows[2][1], 1)
  assert_eq(s.value, 0)

  local s2 = StateMachine.new(0, 'select-all')
  local rt2 = new_runtime()
  local rows2
  rt2:spawn_raw(function()
    rows2 = rt2:perform(Op.all({
      s2:transition_op(supply),
      s2:transition_op(take):or_else(Op.always('empty')),
    }))
  end, 'root')
  assert_status(rt2:run(), 'found')
  assert_eq(rows2[2][1], 'empty')
  assert_eq(s2.value, 1)
end

local function test_flow_sequential_write_read()
  local flow = Flow.new(nil, 'flow-sequential')
  local inlet, outlet = flow:inlet(), flow:outlet()
  local got
  local st = fibers.try_run(function()
    fibers.perform(inlet:write_op('abc'))
    got = fibers.perform(outlet:read_some_op(3))
  end).runtime_status
  assert_status(st, 'found')
  assert_eq(got, 'abc')
end

local function test_flow_tensor_write_read_handoff()
  local flow = Flow.new(nil, 'flow-tensor')
  local inlet, outlet = flow:inlet(), flow:outlet()
  local rows
  local st = fibers.try_run(function()
    rows = fibers.perform(Op.tensor({
      inlet:write_op('abc'),
      outlet:read_some_op(3),
    }))
  end).runtime_status
  assert_status(st, 'found')
  assert_eq(rows[1][1], 3)
  assert_eq(rows[2][1], 'abc')
  assert_eq(Inspect.queued(flow), 0)
end

local function test_flow_all_write_does_not_supply_read()
  local flow = Flow.new(nil, 'flow-all')
  local inlet, outlet = flow:inlet(), flow:outlet()
  local rows
  local st = fibers.try_run(function()
    rows = fibers.perform(Op.all({
      inlet:write_op('abc'),
      outlet:read_some_op(3):or_else(Op.always('empty')),
    }))
  end).runtime_status
  assert_status(st, 'found')
  assert_eq(rows[1][1], 3)
  assert_eq(rows[2][1], 'empty')
  local got
  fibers.run(function()
    got = fibers.perform(outlet:read_some_op(3))
  end)
  assert_eq(got, 'abc')
end

local function test_flow_close_constrains_write()
  local flow = Flow.new(nil, 'flow-close')
  local inlet = flow:inlet()
  local rows
  local st = fibers.try_run(function()
    rows = fibers.perform(Op.tensor({
      inlet:close_op(),
      inlet:write_op('x'),
    }))
  end).runtime_status
  assert_status(st, 'found')
  assert_eq(rows[2][1], nil)
  assert_eq(rows[2][2], FlowErrors.CLOSED)
end

local function test_flow_capacity_and_write_some()
  local flow = Flow.new(3, 'flow-capacity')
  local inlet, outlet = flow:inlet(), flow:outlet()
  local ok, err, n, rest, got
  fibers.run(function()
    ok, err = fibers.perform(inlet:write_op('abcd'))
    n, rest = fibers.perform(inlet:write_some_op('abcd'))
    got = fibers.perform(outlet:read_some_op(10))
  end)
  assert_eq(ok, nil)
  assert_eq(err, FlowErrors.CAPACITY)
  assert_eq(n, 3)
  assert_eq(rest, 'd')
  assert_eq(got, 'abc')
end

local function test_flow_lease_ack_and_return()
  local flow = Flow.new(nil, 'flow-lease')
  local inlet, outlet = flow:inlet(), flow:outlet()
  local lease, ok, got
  fibers.run(function()
    fibers.perform(inlet:write_op('abcdef'))
    lease = fibers.perform(outlet:lease_some_op(3, 'reader'))
    ok = fibers.perform(lease:ack_op(1))
    fibers.perform(lease:release_op())
    got = fibers.perform(outlet:read_some_op(10))
  end)
  assert_eq(lease:bytes(), 'abc')
  assert_eq(ok, true)
  assert_eq(got, 'bcdef')
end

local tests = {
  test_cell_select_tensor_supply_but_all_non_handoff,
  test_flow_sequential_write_read,
  test_flow_tensor_write_read_handoff,
  test_flow_all_write_does_not_supply_read,
  test_flow_close_constrains_write,
  test_flow_capacity_and_write_some,
  test_flow_lease_ack_and_return,
}

for i = 1, #tests do
  tests[i]()
end
print('tests/test_flow_cell_state_machine.lua: ok')

-- Scalar-state-machine Flow built over typed Scalar select transitions.

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
local Op = fibers.Op
local Flow = fibers.Flow
local Runtime = require('fibers.kernel.runtime')

local function fail(msg)
  error(msg, 2)
end
local function assert_eq(actual, expected, msg)
  if actual ~= expected then
    fail(
      (msg or 'assert_eq failed')
        .. ': expected '
        .. tostring(expected)
        .. ', got '
        .. tostring(actual)
    )
  end
end
local function assert_status(st, tag, msg)
  if not st or st.tag ~= tag then
    fail(
      (msg or 'status mismatch')
        .. ': expected '
        .. tostring(tag)
        .. ', got '
        .. tostring(st and st.tag)
    )
  end
end
local function new_runtime(opts)
  return Runtime.new(opts or {})
end

local function test_scalar_select_tensor_supply_but_all_non_handoff()
  local supply = fibers.Scalar.transition({
    name = 'test.scalar.supply',
    mode = 'update',
    step = function(v)
      return v + 1, true
    end,
  })
  local take = fibers.Scalar.transition({
    name = 'test.scalar.take',
    mode = 'select',
    step = function(v)
      if v <= 0 then
        return nil
      end
      return v - 1, v
    end,
  })
  local s = fibers.Scalar.new(0, 'select-law')
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

  local s2 = fibers.Scalar.new(0, 'select-all')
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
  local flow = Flow.new({ name = 'flow-sequential' })
  local inlet, outlet = flow:inlet(), flow:outlet()
  local got
  local st = fibers.try_run(function()
    fibers.perform(inlet:write_op('abc'))
    got = fibers.perform(outlet:read_op(3))
  end).runtime_status
  assert_status(st, 'found')
  assert_eq(got, 'abc')
end

local function test_flow_tensor_write_read_handoff()
  local flow = Flow.new({ name = 'flow-tensor' })
  local inlet, outlet = flow:inlet(), flow:outlet()
  local rows
  local st = fibers.try_run(function()
    rows = fibers.perform(Op.tensor({
      inlet:write_op('abc'),
      outlet:read_op(3),
    }))
  end).runtime_status
  assert_status(st, 'found')
  assert_eq(rows[1][1], 3)
  assert_eq(rows[2][1], 'abc')
  local inspect
  fibers.run(function()
    inspect = fibers.perform(flow:inspect_op())
  end)
  assert_eq(inspect.queued, 0)
end

local function test_flow_all_write_does_not_supply_read()
  local flow = Flow.new({ name = 'flow-all' })
  local inlet, outlet = flow:inlet(), flow:outlet()
  local rows
  local st = fibers.try_run(function()
    rows = fibers.perform(Op.all({
      inlet:write_op('abc'),
      outlet:read_op(3):or_else(Op.always('empty')),
    }))
  end).runtime_status
  assert_status(st, 'found')
  assert_eq(rows[1][1], 3)
  assert_eq(rows[2][1], 'empty')
  local got
  fibers.run(function()
    got = fibers.perform(outlet:read_op(3))
  end)
  assert_eq(got, 'abc')
end

local function test_flow_close_constrains_write()
  local flow = Flow.new({ name = 'flow-close' })
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
  assert_eq(rows[2][2], Flow.Errors.CLOSED)
end

local function test_flow_capacity_and_write_some()
  local flow = Flow.new({ capacity = 3, name = 'flow-capacity' })
  local inlet, outlet = flow:inlet(), flow:outlet()
  local ok, err, n, rest, got
  fibers.run(function()
    ok, err = fibers.perform(inlet:write_op('abcd'))
    n, rest = fibers.perform(inlet:write_some_op('abcd'))
    got = fibers.perform(outlet:read_op(10))
  end)
  assert_eq(ok, nil)
  assert_eq(err, Flow.Errors.CAPACITY)
  assert_eq(n, 3)
  assert_eq(rest, 'd')
  assert_eq(got, 'abc')
end

local function test_flow_lease_ack_and_return()
  local flow = Flow.new({ name = 'flow-lease' })
  local inlet, outlet = flow:inlet(), flow:outlet()
  local lease, ok, got
  fibers.run(function()
    fibers.perform(inlet:write_op('abcdef'))
    lease = fibers.perform(outlet:lease_op(3, 'reader'))
    ok = fibers.perform(lease:ack_op(1))
    fibers.perform(lease:return_op())
    got = fibers.perform(outlet:read_op(10))
  end)
  assert_eq(lease:bytes(), 'abc')
  assert_eq(ok, true)
  assert_eq(got, 'bcdef')
end

local tests = {
  test_scalar_select_tensor_supply_but_all_non_handoff,
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
print('tests/test_flow_scalar_state_machine.lua: ok')

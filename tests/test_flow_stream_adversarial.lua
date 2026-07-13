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
local Stream = fibers.Stream
local Runtime = require('fibers.kernel.runtime')

local function fail(msg)
  error(msg, 2)
end
local function assert_eq(a, b, msg)
  if a ~= b then
    fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a))
  end
end
local function assert_nil(v, msg)
  if v ~= nil then
    fail((msg or 'expected nil') .. ': got ' .. tostring(v))
  end
end
local function assert_truthy(v, msg)
  if not v then
    fail(msg or 'expected truthy')
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

local function test_parallel_lease_and_read_do_not_duplicate_bytes()
  local flow = Flow.new({ name = 'adv-lease-read' })
  local inlet, outlet = flow:inlet(), flow:outlet()
  local rows, inspect, got
  local st = fibers.try_run(function()
    fibers.perform(inlet:write_op('abcdef'))
    rows = fibers.perform(Op.tensor({
      outlet:lease_op(3, 'owner'),
      outlet:read_op(3),
    }))
    inspect = fibers.perform(flow:inspect_op())
    fibers.perform(rows[1][1]:return_op())
    got = fibers.perform(outlet:read_op(10))
  end).runtime_status
  assert_status(st, 'found')
  assert_eq(rows[1][1]:bytes(), 'abc', 'lease should take first bytes')
  assert_eq(rows[2][1], 'def', 'read should take remaining bytes')
  assert_eq(inspect.queued, 0, 'no queued bytes should be duplicated')
  assert_eq(inspect.leased, 3, 'leased bytes remain retained')
  assert_eq(got, 'abc', 'returned lease bytes should re-enter the queue')
end

local function test_parallel_ack_then_return_returns_only_unacked_tail()
  local flow = Flow.new({ name = 'adv-ack-return' })
  local inlet, outlet = flow:inlet(), flow:outlet()
  local lease, rows, got
  local st = fibers.try_run(function()
    fibers.perform(inlet:write_op('abcdef'))
    lease = fibers.perform(outlet:lease_op(3, 'owner'))
    rows = fibers.perform(Op.tensor({
      lease:ack_op(1),
      lease:return_op(),
    }))
    got = fibers.perform(outlet:read_op(10))
  end).runtime_status
  assert_status(st, 'found')
  assert_eq(lease:bytes(), 'abc')
  assert_eq(rows[1][1], true, 'ack should succeed')
  assert_eq(rows[2][1], true, 'return should succeed after ack')
  assert_eq(got, 'bcdef', 'only unacked lease tail should be returned')
end

local function test_input_close_and_read_empty_is_eof_but_queued_data_drains_first()
  local empty = Flow.new({ name = 'adv-empty-close' })
  local eof, eof_err
  local st = fibers.try_run(function()
    fibers.perform(empty:inlet():close_op())
    eof, eof_err = fibers.perform(empty:outlet():read_op(1))
  end).runtime_status
  assert_status(st, 'found')
  assert_eq(eof, nil)
  assert_eq(eof_err, Flow.Errors.EOF)

  local same_world = Flow.new({ name = 'adv-same-world-close' })
  local same_rows
  local st_same = fibers.try_run(function()
    same_rows = fibers.perform(Op.tensor({
      same_world:inlet():close_op(),
      same_world:outlet():read_op(1):or_else(Op.always('not-yet-eof')),
    }))
  end).runtime_status
  assert_status(st_same, 'found')
  assert_eq(
    same_rows[2][1],
    'not-yet-eof',
    'same-world close should not fabricate EOF for an empty read'
  )

  local flow = Flow.new({ name = 'adv-close-drain' })
  local data, eof, eof_err
  local st2 = fibers.try_run(function()
    fibers.perform(flow:inlet():write_op('abc'))
    fibers.perform(flow:inlet():close_op())
    data = fibers.perform(flow:outlet():read_op(10))
    eof, eof_err = fibers.perform(flow:outlet():read_op(1))
  end).runtime_status
  assert_status(st2, 'found')
  assert_eq(data, 'abc')
  assert_eq(eof, nil)
  assert_eq(eof_err, Flow.Errors.EOF)
end

local function test_shutdown_while_lease_active_settles_and_invalidates_lease()
  local flow = Flow.new({ name = 'adv-shutdown-lease' })
  local inlet, outlet = flow:inlet(), flow:outlet()
  local lease, inspect, ack_ok, ack_err
  local st = fibers.try_run(function()
    fibers.perform(inlet:write_op('abcdef'))
    lease = fibers.perform(outlet:lease_op(3, 'owner'))
    fibers.perform(outlet:shutdown_op('stop'))
    inspect = fibers.perform(flow:inspect_op())
    ack_ok, ack_err = fibers.perform(lease:ack_op(1))
  end).runtime_status
  assert_status(st, 'found')
  assert_eq(inspect.retained, 0, 'shutdown should drop queued and leased bytes')
  assert_eq(inspect.leased, 0)
  assert_eq(inspect.queued, 0)
  assert_eq(ack_ok, false, 'old lease should no longer be live')
  assert_eq(ack_err, Flow.Errors.NO_LEASE)
end

local function test_capacity_release_handoff_tensor_but_not_all()
  local flow = Flow.new({ name = 'adv-capacity-all', capacity = 3 })
  local inlet, outlet = flow:inlet(), flow:outlet()
  local lease, rows, got
  local st = fibers.try_run(function()
    fibers.perform(inlet:write_op('abc'))
    lease = fibers.perform(outlet:lease_op(3, 'owner'))
    rows = fibers.perform(Op.all({
      lease:ack_op(3),
      inlet:write_op('def'):or_else(Op.always('blocked')),
    }))
    got = fibers.perform(outlet:read_op(10):or_else(Op.always('empty')))
  end).runtime_status
  assert_status(st, 'found')
  assert_eq(rows[1][1], true)
  assert_eq(rows[2][1], 'blocked', 'all should not let ack capacity supply sibling write')
  assert_eq(got, 'empty')

  local flow2 = Flow.new({ name = 'adv-capacity-tensor', capacity = 3 })
  local inlet2, outlet2 = flow2:inlet(), flow2:outlet()
  local lease2, rows2, got2
  local st2 = fibers.try_run(function()
    fibers.perform(inlet2:write_op('abc'))
    lease2 = fibers.perform(outlet2:lease_op(3, 'owner'))
    rows2 = fibers.perform(Op.tensor({
      lease2:ack_op(3),
      inlet2:write_op('def'),
    }))
    got2 = fibers.perform(outlet2:read_op(10))
  end).runtime_status
  assert_status(st2, 'found')
  assert_eq(rows2[1][1], true)
  assert_eq(rows2[2][1], 3, 'tensor should allow capacity handoff')
  assert_eq(got2, 'def')
end

local function test_stream_memory_backpressure_with_small_capacity()
  local a, b = Stream.memory_pair({ name = 'adv-stream-backpressure', capacity = 3 })
  local writer = a:writer()
  local reader = b:reader()
  local rt = Runtime.new({ quiet_deadlock = true })
  local first, second, read
  rt:spawn_raw(function()
    first = rt:perform(writer:write_op('abc'))
  end, 'first-write')
  assert_status(rt:run(), 'found')
  assert_eq(first, 3)

  rt:spawn_raw(function()
    second = rt:perform(writer:write_op('def'))
  end, 'blocked-write')
  local pending = rt:run()
  assert_eq(pending.tag, 'quiescent', 'capacity retry has no external wake interest')
  assert_nil(second)

  rt:spawn_raw(function()
    read = rt:perform(reader:read_op(3))
  end, 'reader')
  assert_status(rt:run(), 'found')
  assert_eq(read, 'abc')
  assert_eq(second, 3, 'second write should complete after read releases capacity')
end

local tests = {
  test_parallel_lease_and_read_do_not_duplicate_bytes,
  test_parallel_ack_then_return_returns_only_unacked_tail,
  test_input_close_and_read_empty_is_eof_but_queued_data_drains_first,
  test_shutdown_while_lease_active_settles_and_invalidates_lease,
  test_capacity_release_handoff_tensor_but_not_all,
  test_stream_memory_backpressure_with_small_capacity,
}

for i = 1, #tests do
  tests[i]()
end
print('tests/test_flow_stream_adversarial.lua: ok')

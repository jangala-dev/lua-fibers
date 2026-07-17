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
local Runtime = require('fibers.runtime')
local Flow = require('fibers.flow')
local Errors = require('fibers.flow.errors')

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

local function drive_until(rt, pred, label)
  for _ = 1, 120 do
    if pred() then
      return true
    end
    rt:step()
  end
  fail(label or 'runtime did not reach expected state')
end

-- A capacity lease reserves producer-side room before an irreversible source
-- obtains bytes, then atomically publishes the bytes into the Flow.
do
  local flow = Flow.new({ name = 'public-space-lease', capacity = 4 })
  local lease, committed, got, snap
  local st = fibers.try_run(function()
    lease = fibers.perform(flow:inlet():reserve_some_op(3, 'host-reader'))
    snap = fibers.perform(flow:inspect_op())
    committed = fibers.perform(lease:commit_op('ab'))
    got = fibers.perform(flow:outlet():read_exactly_op(2))
  end).runtime_status
  assert_eq(st.tag, 'found')
  assert_truthy(type(lease.capacity) == 'function', 'reservation should return a SpaceLease')
  assert_eq(lease:capacity(), 3)
  assert_eq(snap.reserved, 3, 'reserved space should count as retained capacity')
  assert_eq(snap.free, 1)
  assert_eq(committed, 2)
  assert_eq(got, 'ab')
end

-- Reserved capacity blocks other producers until it is committed or released.
do
  local rt = Runtime.new()
  local flow = Flow.new({ name = 'public-space-backpressure', capacity = 3 })
  local lease, written
  rt:spawn_raw(function()
    lease = rt:perform(flow:inlet():reserve_some_op(3, 'external-source'))
  end, 'reserve')
  assert_eq(rt:run().tag, 'found')

  rt:spawn_raw(function()
    written = rt:perform(flow:inlet():write_op('x'))
  end, 'writer')
  local pending = rt:run()
  assert_eq(pending.tag, 'quiescent')
  assert_nil(written, 'writer should wait while capacity is reserved')

  rt:spawn_raw(function()
    rt:perform(lease:release_op())
  end, 'release')
  drive_until(rt, function()
    return written == 1
  end, 'releasing capacity should admit the writer')
  assert_eq(written, 1)
end

-- A producer cannot publish more bytes than it reserved; the reservation
-- remains live until explicitly released or failed.
do
  local flow = Flow.new({ name = 'public-space-overcommit', capacity = 3 })
  local lease, n, err, released
  local st = fibers.try_run(function()
    lease = fibers.perform(flow:inlet():reserve_some_op(2, 'external-source'))
    n, err = fibers.perform(lease:commit_op('abc'))
    released = fibers.perform(lease:release_op())
  end).runtime_status
  assert_eq(st.tag, 'found')
  assert_nil(n)
  assert_eq(err, Errors.SPACE_COMMIT_TOO_LARGE)
  assert_eq(released, true)
end

-- A losing reservation option leaves no retained capacity behind.
do
  local flow = Flow.new({ name = 'public-space-losing-choice', capacity = 3 })
  local result, snap
  local st = fibers.try_run(function()
    result = fibers.perform(
      fibers.choice(
        fibers.always('winner'),
        flow:inlet():reserve_some_op(3, 'loser'):map(function()
          return 'loser'
        end)
      )
    )
    snap = fibers.perform(flow:inspect_op())
  end, { choice_seed = 3 }).runtime_status
  assert_eq(st.tag, 'found')
  assert_eq(result, 'winner')
  assert_eq(snap.reserved, 0)
  assert_eq(snap.retained, 0)
end

-- The version 1 Flow surface is intentionally alias-free.
do
  local flow = Flow.new({ name = 'public-flow-surface', capacity = 8 })
  local inlet, outlet = flow:inlet(), flow:outlet()

  for _, name in ipairs({
    'append_op',
    'append_some_op',
    'reserve_op',
    'drain_op',
    'drained_op',
    'shutdown_op',
    'exit_op',
    'error_op',
  }) do
    assert_nil(inlet[name], 'Inlet should not expose ' .. name)
  end

  for _, name in ipairs({
    'read_op',
    'peek_op',
    'peek_some_op',
    'read_including_op',
    'lease_op',
    'return_lease_op',
    'ack_lease_op',
    'fail_write_op',
    'shutdown_op',
    'exit_op',
    'error_op',
  }) do
    assert_nil(outlet[name], 'Outlet should not expose ' .. name)
  end

  assert_nil(flow.close_op)
  assert_nil(flow.shutdown_op)
  assert_nil(flow.drained_op)
  assert_nil(flow.exit_op)
  assert_nil(Flow.Lease)
  assert_nil(Flow.SpaceLease)
  assert_nil(Flow.Reservoir)
  assert_nil(Flow.Errors)
  assert_eq(Flow.Error.EOF, 'eof')
  assert_eq(Flow.Error.BROKEN_PIPE, 'broken_pipe')

  local data_lease, space_lease
  fibers.run(function()
    fibers.perform(inlet:write_op('x'))
    data_lease = fibers.perform(outlet:lease_some_op(1, 'consumer'))
    fibers.perform(data_lease:release_op())
    space_lease = fibers.perform(inlet:reserve_some_op(1, 'producer'))
    fibers.perform(space_lease:release_op())
  end)

  assert_nil(data_lease.return_op)
  assert_nil(data_lease.bytes_value)
  assert_nil(data_lease.length_value)
  assert_nil(space_lease.capacity_value)
end

-- Option records use only the version 1 field names.
do
  local flow = Flow.new({ name = 'public-flow-options', capacity = 16 })
  local ok, err = pcall(function()
    flow:outlet():read_line_op({ limit = 4 })
  end)
  assert_eq(ok, false)
  assert_truthy(tostring(err):find('does not accept limit', 1, true))

  ok, err = pcall(function()
    flow:outlet():read_line_op({ sep = '\n' })
  end)
  assert_eq(ok, false)
  assert_truthy(tostring(err):find('does not accept sep', 1, true))

  ok, err = pcall(function()
    flow:outlet():read_all_op({ unlimited = true })
  end)
  assert_eq(ok, false)
  assert_truthy(tostring(err):find('does not accept unlimited', 1, true))
end

print('tests/public/test_flow.lua: ok')

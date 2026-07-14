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
local Inspect = require('tests.support.flow_inspect')

local fibers = require('fibers')
local FibersRuntime = require('fibers.runtime')
local FibersRegion = require('fibers.lifetime.region')
local FibersStream = require('fibers.stream')
local Stream = FibersStream
local Fake = Stream.backend.Fake

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

local function drive_until(rt, pred, label)
  for _ = 1, 120 do
    if pred() then
      return true
    end
    local st = rt:run()
    if pred() then
      return true
    end
    if st.tag == 'idle' or st.tag == 'quiescent' then
      break
    end
  end
  fail(label or 'runtime did not reach expected state')
end

-- Consumer shutdown discards retained queued bytes and gives waiting flush a fate.
do
  local rt = FibersRuntime.new()
  local a, b = Stream.memory_pair({ name = 'settle-peer-close', capacity = 10 })
  local flushed, flush_err
  rt:spawn_raw(function()
    rt:perform(a:writer():write_op('abc'))
    flushed, flush_err = rt:perform(a:writer():flush_op())
  end, 'writer')
  for _ = 1, 10 do
    if Inspect.data(b:reader().flow.reservoir) == 'abc' and flushed == nil then
      break
    end
    rt:run()
  end
  assert_nil(flushed, 'flush should wait while bytes are retained')
  assert_eq(
    Inspect.data(b:reader().flow.reservoir),
    'abc',
    'bytes should be queued before peer close'
  )

  rt:spawn_raw(function()
    rt:perform(b:reader():shutdown_op('reader_closed'))
  end, 'reader-close')
  drive_until(rt, function()
    return flush_err == 'reader_closed'
  end, 'peer close should settle retained bytes and fail flush with close reason')
  assert_nil(flushed)
  assert_eq(flush_err, 'reader_closed')
  assert_eq(
    Inspect.data(b:reader().flow.reservoir),
    '',
    'peer close should discard queued retained bytes'
  )
  assert_eq(
    Inspect.leased_bytes(b:reader().flow.reservoir),
    0,
    'peer close should discard leased retained bytes'
  )
end

-- Flush succeeds after previously written bytes have already been consumed, even
-- if the peer closes afterwards.  Flush is about retained bytes, not future
-- writability.
do
  local a, b = Stream.memory_pair({ name = 'flush-after-delivery', capacity = 10 })
  local flushed, flush_err, later_n, later_err
  local st = fibers.try_run(function()
    fibers.perform(a:writer():write_op('abc'))
    assert_eq(fibers.perform(b:reader():read_exactly_op(3)), 'abc')
    fibers.perform(b:reader():shutdown_op('reader_closed'))
    flushed, flush_err = fibers.perform(a:writer():flush_op())
    later_n, later_err = fibers.perform(a:writer():write_op('z'))
  end).runtime_status
  assert_status(st, 'found')
  assert_eq(flushed, true, 'flush should succeed when no prior bytes are retained')
  assert_nil(flush_err)
  assert_nil(later_n)
  assert_eq(later_err, 'broken_pipe', 'future writes should still fail after peer close')
end

-- Graceful writer shutdown still drains queued bytes to EOF; it does not discard data.
do
  local a, b = Stream.memory_pair({ name = 'settle-graceful-eof', capacity = 10 })
  local one, two, err
  local st = fibers.try_run(function()
    fibers.perform(a:writer():write_op('abc'))
    fibers.perform(a:writer():shutdown_op())
    one = fibers.perform(b:reader():read_some_op(10))
    two, err = fibers.perform(b:reader():read_some_op(10))
  end).runtime_status
  assert_status(st, 'found')
  assert_eq(one, 'abc')
  assert_nil(two)
  assert_eq(err, 'eof')
end

-- Backend write failure settles an active write-pump lease and wakes flush with the backend error.
do
  local rt = FibersRuntime.new()
  local region = FibersRegion.new('settle-backend-region')
  local backend = Fake.new({ name = 'settle-backend', write_blocked = true })
  local stream, flushed, flush_err
  rt:spawn_raw(function()
    stream = rt:perform(
      Stream.open_backend_in_op(
        region,
        backend,
        { name = 'settle-backend-stream', write_capacity = 3 }
      )
    )
    rt:perform(stream:writer():write_op('abc'))
    flushed, flush_err = rt:perform(stream:writer():flush_op())
  end, 'writer')
  for _ = 1, 20 do
    if stream and Inspect.first_lease_bytes(stream:writer().flow.reservoir) == 'abc' then
      break
    end
    rt:run()
  end
  assert_eq(
    Inspect.first_lease_bytes(stream:writer().flow.reservoir),
    'abc',
    'write pump should hold an active lease'
  )
  assert_nil(flushed, 'flush should wait while lease is retained')

  backend:fail_writes('connection_reset')
  backend:unblock_writes()
  drive_until(rt, function()
    return flush_err == 'connection_reset'
  end, 'backend failure should fail retained lease')
  assert_nil(flushed)
  assert_eq(flush_err, 'connection_reset')
  assert_nil(
    Inspect.first_lease_bytes(stream:writer().flow.reservoir),
    'backend failure should settle active lease'
  )
  assert_eq(
    Inspect.leased_bytes(stream:writer().flow.reservoir),
    0,
    'backend failure should release leased capacity'
  )
end

-- A backend write that claims to accept more than the lease length is a protocol error;
-- the active lease is still settled by the failure path.
do
  local rt = FibersRuntime.new()
  local region = FibersRegion.new('settle-protocol-region')
  local backend = Fake.new({ name = 'settle-protocol-backend' })
  function backend:write(bytes)
    return #bytes + 1
  end
  local stream, flushed, flush_err
  rt:spawn_raw(function()
    stream = rt:perform(
      Stream.open_backend_in_op(
        region,
        backend,
        { name = 'settle-protocol-stream', write_capacity = 3 }
      )
    )
    rt:perform(stream:writer():write_op('abc'))
    flushed, flush_err = rt:perform(stream:writer():flush_op())
  end, 'writer')
  drive_until(rt, function()
    return flush_err == 'backend_protocol_error'
  end, 'invalid backend write count should fail output')
  assert_nil(flushed)
  assert_eq(flush_err, 'backend_protocol_error')
  assert_nil(
    Inspect.first_lease_bytes(stream:writer().flow.reservoir),
    'protocol error should settle active lease'
  )
  assert_eq(
    Inspect.leased_bytes(stream:writer().flow.reservoir),
    0,
    'protocol error should release leased capacity'
  )
end

print('tests/test_flow_settlement.lua: ok')

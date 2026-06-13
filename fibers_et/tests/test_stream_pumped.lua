package.path = table.concat({'./?.lua','./?/init.lua','./?/?.lua',package.path}, ';')

local fibers = require('fibers')
local Op = fibers.Op
local Stream = fibers.Stream
local Fake = Stream.backend.Fake

local function fail(msg) error(msg, 2) end
local function assert_eq(a, b, msg) if a ~= b then fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a)) end end
local function assert_nil(v, msg) if v ~= nil then fail((msg or 'expected nil') .. ': got ' .. tostring(v)) end end
local function assert_truthy(v, msg) if not v then fail(msg or 'expected truthy') end end
local function assert_status(st, tag, msg) if not st or st.tag ~= tag then fail((msg or 'status mismatch') .. ': expected ' .. tostring(tag) .. ', got ' .. tostring(st and st.tag)) end end

local function drive_until(rt, pred, label)
  for _ = 1, 100 do
    if pred() then return true end
    local st = rt:run()
    if pred() then return true end
    if st.tag == 'idle' or st.tag == 'absent' then break end
  end
  fail(label or 'runtime did not reach expected state')
end

-- Opening a backend stream is transactional. A losing open starts no pump task.
do
  local backend = Fake.new({ name = 'losing-open-backend' })
  local region = fibers.Region.new('losing-open-region')
  local got
  local st = fibers.run(function()
    got = fibers.perform(Op.choice(
      Op.always('winner'),
      Stream.open_backend_op(region, backend, { name = 'losing-open-stream' }):map(function() return 'loser' end)
    ))
  end)
  assert_status(st, 'found')
  assert_eq(got, 'winner')
  assert_nil(backend.runtime, 'losing open should not start or bind pump tasks')
end

-- Host input enters the stream only through the read pump committing bytes into the incoming ByteQueue.
do
  local rt = fibers.Runtime.new()
  local region = fibers.Region.new('read-region')
  local backend = Fake.new({ name = 'read-backend' })
  local stream, got
  rt:spawn_raw(function()
    stream = rt:perform(Stream.open_backend_op(region, backend, { name = 'read-stream' }))
    got = rt:perform(stream:read_exactly_op(3))
  end, 'root')
  assert_status(rt:run(), 'found')
  assert_nil(got)
  backend:feed_read('abc')
  drive_until(rt, function() return got == 'abc' end, 'host read bytes should become stream bytes')
  assert_eq(got, 'abc')
end

-- The read pump honours input ByteQueue capacity.
do
  local rt = fibers.Runtime.new()
  local region = fibers.Region.new('capacity-read-region')
  local backend = Fake.new({ name = 'capacity-read-backend' })
  local stream, first, second
  rt:spawn_raw(function()
    stream = rt:perform(Stream.open_backend_op(region, backend, { name = 'capacity-read-stream', read_capacity = 2, read_chunk_size = 4 }))
    first = rt:perform(stream:read_exactly_op(2))
    second = rt:perform(stream:read_exactly_op(2))
  end, 'root')
  assert_status(rt:run(), 'found')
  backend:feed_read('abcd')
  drive_until(rt, function() return first == 'ab' end, 'first capacity-limited read')
  assert_eq(first, 'ab')
  drive_until(rt, function() return second == 'cd' end, 'second capacity-limited read')
  assert_eq(second, 'cd')
end

-- Writes append to the outgoing queue and the write pump sends committed bytes to the backend.
do
  local rt = fibers.Runtime.new()
  local region = fibers.Region.new('write-region')
  local backend = Fake.new({ name = 'write-backend' })
  local stream, flushed
  rt:spawn_raw(function()
    stream = rt:perform(Stream.open_backend_op(region, backend, { name = 'write-stream' }))
    rt:perform(stream:write_op('abc'))
    flushed = rt:perform(stream:flush_op())
  end, 'root')
  drive_until(rt, function() return flushed == true end, 'write should flush')
  assert_eq(backend:written(), 'abc')
end

-- Losing writes to a host-pumped stream publish nothing to the backend.
do
  local rt = fibers.Runtime.new()
  local region = fibers.Region.new('losing-write-region')
  local backend = Fake.new({ name = 'losing-write-backend' })
  local stream, got
  rt:spawn_raw(function()
    stream = rt:perform(Stream.open_backend_op(region, backend, { name = 'losing-write-stream' }))
    got = rt:perform(Op.choice(
      Op.always('winner'),
      stream:write_op('abc'):map(function() return 'loser' end)
    ))
  end, 'root')
  drive_until(rt, function() return got == 'winner' end, 'losing write choice')
  assert_eq(backend:written(), '')
end

-- Partial host writes preserve ordering and are acknowledged exactly.
do
  local rt = fibers.Runtime.new()
  local region = fibers.Region.new('partial-write-region')
  local backend = Fake.new({ name = 'partial-write-backend', write_chunk_size = 2 })
  local stream, flushed
  rt:spawn_raw(function()
    stream = rt:perform(Stream.open_backend_op(region, backend, { name = 'partial-write-stream', write_chunk_size = 6 }))
    rt:perform(stream:write_op('abcdef'))
    flushed = rt:perform(stream:flush_op())
  end, 'root')
  drive_until(rt, function() return flushed == true end, 'partial writes should eventually flush')
  assert_eq(backend:written(), 'abcdef')
end

-- Would-block preserves an in-flight claim; flush waits until the claim is acknowledged.
do
  local rt = fibers.Runtime.new()
  local region = fibers.Region.new('would-block-region')
  local backend = Fake.new({ name = 'would-block-backend', write_blocked = true })
  local stream, flushed
  rt:spawn_raw(function()
    stream = rt:perform(Stream.open_backend_op(region, backend, { name = 'would-block-stream' }))
    rt:perform(stream:write_op('abc'))
    flushed = rt:perform(stream:flush_op())
  end, 'root')
  -- Let the write commit and the pump claim the bytes, then stop at writability.
  for _ = 1, 10 do if stream and stream.outgoing.inflight then break end; rt:run() end
  assert_truthy(stream and stream.outgoing.inflight, 'write pump should hold an in-flight claim while blocked')
  assert_nil(flushed, 'flush should wait while bytes are in flight')
  assert_eq(backend:written(), '')
  backend:unblock_writes()
  drive_until(rt, function() return flushed == true end, 'unblocked write should flush')
  assert_eq(backend:written(), 'abc')
end

-- EOF becomes committed stream state.
do
  local rt = fibers.Runtime.new()
  local region = fibers.Region.new('eof-region')
  local backend = Fake.new({ name = 'eof-backend' })
  local stream, first, second, err
  rt:spawn_raw(function()
    stream = rt:perform(Stream.open_backend_op(region, backend, { name = 'eof-stream' }))
    first = rt:perform(stream:read_exactly_op(3))
    second, err = rt:perform(stream:read_some_op(1))
  end, 'root')
  assert_status(rt:run(), 'found')
  backend:feed_read('abc')
  backend:feed_eof()
  drive_until(rt, function() return err == 'eof' end, 'EOF should reach stream')
  assert_eq(first, 'abc')
  assert_nil(second)
  assert_eq(err, 'eof')
end

-- shutdown_write drains pending/in-flight data before shutting down the backend write side.
do
  local rt = fibers.Runtime.new()
  local region = fibers.Region.new('shutdown-write-region')
  local backend = Fake.new({ name = 'shutdown-write-backend', write_blocked = true })
  local stream, done
  rt:spawn_raw(function()
    stream = rt:perform(Stream.open_backend_op(region, backend, { name = 'shutdown-write-stream' }))
    rt:perform(stream:write_op('abc'))
    rt:perform(stream:shutdown_write_op())
    done = rt:perform(stream:flush_op())
  end, 'root')
  for _ = 1, 10 do if stream and stream.outgoing.inflight then break end; rt:run() end
  assert_nil(backend.shutdown_write_reason, 'backend write should not shut down before draining')
  backend:unblock_writes()
  drive_until(rt, function() return done == true and backend.shutdown_write_reason ~= nil end, 'shutdown should happen after drain')
  assert_eq(backend:written(), 'abc')
end

-- Host write errors become committed stream write errors.
do
  local rt = fibers.Runtime.new()
  local region = fibers.Region.new('write-error-region')
  local backend = Fake.new({ name = 'write-error-backend' })
  backend:fail_writes('connection_reset')
  local stream, flushed, flush_err, n, err
  rt:spawn_raw(function()
    stream = rt:perform(Stream.open_backend_op(region, backend, { name = 'write-error-stream' }))
    rt:perform(stream:write_op('abc'))
    flushed, flush_err = rt:perform(stream:flush_op())
    n, err = rt:perform(stream:write_op('d'))
  end, 'root')
  drive_until(rt, function() return err == 'connection_reset' end, 'write error should commit')
  assert_nil(flushed)
  assert_eq(flush_err, 'connection_reset')
  assert_nil(n)
  assert_eq(err, 'connection_reset')
end

print('tests/test_stream_pumped.lua: ok')

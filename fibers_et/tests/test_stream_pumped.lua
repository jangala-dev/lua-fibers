package.path = table.concat({'./?.lua','./?/init.lua','./?/?.lua',package.path}, ';')
local Inspect = require('tests.flow_inspect')

local fibers = require('fibers')
local Op = fibers.Op
local Stream = fibers.Stream
local Fake = Stream.backend.Fake

local function fail(msg) error(msg, 2) end
local function assert_eq(a, b, msg) if a ~= b then fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a)) end end
local function assert_nil(v, msg) if v ~= nil then fail((msg or 'expected nil') .. ': got ' .. tostring(v)) end end
local function assert_truthy(v, msg) if not v then fail(msg or 'expected truthy') end end
local function assert_status(st, tag, msg) if not st or st.tag ~= tag then fail((msg or 'status mismatch') .. ': expected ' .. tostring(tag) .. ', got ' .. tostring(st and st.tag)) end end
local function assert_not_eq(a, b, msg) if a == b then fail((msg or 'assert_not_eq failed') .. ': both were ' .. tostring(a)) end end

local function drive_until(rt, pred, label)
  for _ = 1, 100 do
    if pred() then return true end
    local st = rt:run()
    if pred() then return true end
    if st.tag == 'idle' or st.tag == 'quiescent' then break end
  end
  fail(label or 'runtime did not reach expected state')
end

-- Opening a backend stream is transactional. A losing open starts no pump task.
do
  local backend = Fake.new({ name = 'losing-open-backend' })
  local region = fibers.Region.new('losing-open-region')
  local got
  local st = fibers.try_run(function()
    got = fibers.perform(Op.choice(
      Op.always('winner'),
      Stream.open_backend_in_op(region, backend, { name = 'losing-open-stream' }):map(function() return 'loser' end)
    ))
  end).runtime_status
  assert_status(st, 'found')
  assert_eq(got, 'winner')
  assert_nil(backend.runtime, 'losing open should not start or bind pump tasks')
  assert_nil(backend.stream, 'losing open should not attach backend to an uncommitted stream')
end

-- Host backend streams expose stable reader and writer capabilities.
do
  local rt = fibers.Runtime.new()
  local region = fibers.Region.new('compound-region')
  local backend = Fake.new({ name = 'compound-backend' })
  local stream
  rt:spawn_raw(function()
    stream = rt:perform(Stream.open_backend_in_op(region, backend, { name = 'compound-stream' }))
  end, 'root')
  assert_status(rt:run(), 'found')
  assert_truthy(stream, 'open_backend_op should return a stream')
  assert_truthy(stream:reader() and stream:writer(), 'stream should expose reader and writer handles')
  assert_eq(stream:reader(), stream:reader(), 'reader handle should be stable')
  assert_eq(stream:writer(), stream:writer(), 'writer handle should be stable')
  assert_nil(stream.read_line_op, 'duplex should not expose reader methods directly')
  assert_nil(stream.write_op, 'duplex should not expose writer methods directly')
end

-- Flow surfaces are capability-specific; looping friendly methods and duplex byte ops are absent.
do
  local a, _b = Stream.memory_pair({ name = 'no-friendly-stream' })
  assert_nil(a.read, 'stream should not expose friendly read')
  assert_nil(a.write, 'stream should not expose friendly write')
  assert_nil(a.close, 'stream should not expose friendly close')
  assert_nil(a.read_line_op, 'duplex should not expose reader methods directly')
  assert_nil(a.write_op, 'duplex should not expose writer methods directly')
end

-- Pump strategy is a replaceable host-stream detail.
do
  local rt = fibers.Runtime.new()
  local region = fibers.Region.new('custom-strategy-region')
  local backend = Fake.new({ name = 'custom-strategy-backend' })
  local seen_stream, seen_region, stream
  local strategy = function(s, r, _opts)
    seen_stream = s
    seen_region = r
    s.pump_task = 'custom-pump-placeholder'
    return Op.always(s)
  end
  rt:spawn_raw(function()
    stream = rt:perform(Stream.open_backend_in_op(region, backend, { name = 'custom-strategy-stream', pump_strategy = strategy }))
  end, 'root')
  assert_status(rt:run(), 'found')
  assert_eq(seen_stream, stream, 'custom strategy should receive compound stream')
  assert_eq(seen_region, region, 'custom strategy should receive owning region')
  assert_eq(stream.pump_task, 'custom-pump-placeholder')
end

-- Host input enters the stream only through the read pump committing bytes into the incoming Flow reservoir.
do
  local rt = fibers.Runtime.new()
  local region = fibers.Region.new('read-region')
  local backend = Fake.new({ name = 'read-backend' })
  local stream, got
  rt:spawn_raw(function()
    stream = rt:perform(Stream.open_backend_in_op(region, backend, { name = 'read-stream' }))
    got = rt:perform(stream:reader():read_exactly_op(3))
  end, 'root')
  assert_status(rt:run(), 'found')
  assert_nil(got)
  backend:feed_read('abc')
  drive_until(rt, function() return got == 'abc' end, 'host read bytes should become stream bytes')
  assert_eq(got, 'abc')
end

-- The read pump honours input Flow reservoir capacity.
do
  local rt = fibers.Runtime.new()
  local region = fibers.Region.new('capacity-read-region')
  local backend = Fake.new({ name = 'capacity-read-backend' })
  local stream, first, second
  rt:spawn_raw(function()
    stream = rt:perform(Stream.open_backend_in_op(region, backend, { name = 'capacity-read-stream', read_capacity = 2, read_chunk_size = 4 }))
    first = rt:perform(stream:reader():read_exactly_op(2))
    second = rt:perform(stream:reader():read_exactly_op(2))
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
    stream = rt:perform(Stream.open_backend_in_op(region, backend, { name = 'write-stream' }))
    rt:perform(stream:writer():write_op('abc'))
    flushed = rt:perform(stream:writer():flush_op())
  end, 'root')
  drive_until(rt, function() return flushed == true end, 'write should flush')
  assert_eq(backend:written(), 'abc')
end

-- Losing writes to a host-pumped stream discharge nothing to the backend.
do
  local rt = fibers.Runtime.new()
  local region = fibers.Region.new('losing-write-region')
  local backend = Fake.new({ name = 'losing-write-backend' })
  local stream, got
  rt:spawn_raw(function()
    stream = rt:perform(Stream.open_backend_in_op(region, backend, { name = 'losing-write-stream' }))
    got = rt:perform(Op.choice(
      Op.always('winner'),
      stream:writer():write_op('abc'):map(function() return 'loser' end)
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
    stream = rt:perform(Stream.open_backend_in_op(region, backend, { name = 'partial-write-stream', write_chunk_size = 6 }))
    rt:perform(stream:writer():write_op('abcdef'))
    flushed = rt:perform(stream:writer():flush_op())
  end, 'root')
  drive_until(rt, function() return flushed == true end, 'partial writes should eventually flush')
  assert_eq(backend:written(), 'abcdef')
end

-- Would-block preserves an in-flight lease; flush waits until the lease is acknowledged.
do
  local rt = fibers.Runtime.new()
  local region = fibers.Region.new('would-block-region')
  local backend = Fake.new({ name = 'would-block-backend', write_blocked = true })
  local stream, flushed
  rt:spawn_raw(function()
    stream = rt:perform(Stream.open_backend_in_op(region, backend, { name = 'would-block-stream' }))
    rt:perform(stream:writer():write_op('abc'))
    flushed = rt:perform(stream:writer():flush_op())
  end, 'root')
  -- Let the write commit and the pump lease the bytes, then stop at writability.
  for _ = 1, 10 do if stream and Inspect.first_lease_bytes(stream:writer().flow.reservoir) ~= nil and Inspect.first_lease_bytes(stream:writer().flow.reservoir) ~= "" then break end; rt:run() end
  assert_truthy(stream and Inspect.first_lease_bytes(stream:writer().flow.reservoir) ~= nil and Inspect.first_lease_bytes(stream:writer().flow.reservoir) ~= "", 'write pump should hold an in-flight lease while blocked')
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
    stream = rt:perform(Stream.open_backend_in_op(region, backend, { name = 'eof-stream' }))
    first = rt:perform(stream:reader():read_exactly_op(3))
    second, err = rt:perform(stream:reader():read_some_op(1))
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
    stream = rt:perform(Stream.open_backend_in_op(region, backend, { name = 'shutdown-write-stream' }))
    rt:perform(stream:writer():write_op('abc'))
    rt:perform(stream:writer():shutdown_op())
    done = rt:perform(stream:writer():flush_op())
  end, 'root')
  for _ = 1, 10 do if stream and Inspect.first_lease_bytes(stream:writer().flow.reservoir) ~= nil and Inspect.first_lease_bytes(stream:writer().flow.reservoir) ~= "" then break end; rt:run() end
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
    stream = rt:perform(Stream.open_backend_in_op(region, backend, { name = 'write-error-stream' }))
    rt:perform(stream:writer():write_op('abc'))
    flushed, flush_err = rt:perform(stream:writer():flush_op())
    n, err = rt:perform(stream:writer():write_op('d'))
  end, 'root')
  drive_until(rt, function() return err == 'connection_reset' end, 'write error should commit')
  assert_nil(flushed)
  assert_eq(flush_err, 'connection_reset')
  assert_nil(n)
  assert_eq(err, 'connection_reset')
end


-- A pump lease keeps byte capacity reserved until the host acknowledges it.
do
  local rt = fibers.Runtime.new()
  local region = fibers.Region.new('lease-capacity-region')
  local backend = Fake.new({ name = 'lease-capacity-backend', write_blocked = true })
  local stream, second_done, flushed
  rt:spawn_raw(function()
    stream = rt:perform(Stream.open_backend_in_op(region, backend, { name = 'lease-capacity-stream', write_capacity = 3 }))
    rt:perform(stream:writer():write_op('abc'))
    flushed = rt:perform(stream:writer():flush_op())
  end, 'writer1')
  for _ = 1, 10 do
    if stream and Inspect.first_lease_bytes(stream:writer().flow.reservoir) ~= nil and Inspect.first_lease_bytes(stream:writer().flow.reservoir) ~= '' then break end
    rt:run()
  end
  assert_eq(Inspect.first_lease_bytes(stream:writer().flow.reservoir), 'abc', 'pump should have leased the first write')
  assert_eq((stream:writer().flow.reservoir.limit - (#(stream:writer().flow.reservoir.data or '') + Inspect.leased_bytes(stream:writer().flow.reservoir))), 0, 'leased bytes should still reserve capacity')
  rt:spawn_raw(function() second_done = rt:perform(stream:writer():write_op('d')) end, 'writer2')
  assert_status(rt:run(), 'pending')
  assert_nil(second_done, 'second write should wait while leased bytes hold capacity')
  assert_nil(flushed, 'flush should wait while lease is blocked')
  backend:unblock_writes()
  drive_until(rt, function() return second_done == 1 and flushed == true end, 'acknowledged lease should release capacity')
  assert_eq(backend:written(), 'abcd')
end


-- The read pump notices reader shutdown even while backend readability never arrives.
do
  local rt = fibers.Runtime.new()
  local region = fibers.Region.new('blocked-read-close-region')
  local backend = Fake.new({ name = 'blocked-read-close-backend', read_blocked = true })
  local stream
  rt:spawn_raw(function()
    stream = rt:perform(Stream.open_backend_in_op(region, backend, { name = 'blocked-read-close-stream' }))
  end, 'open-blocked-read')
  assert_status(rt:run(), 'found')
  rt:spawn_raw(function()
    rt:perform(stream:reader():shutdown_op('close_reader'))
  end, 'close-reader')
  drive_until(rt, function() return backend.shutdown_read_reason == 'reader_closed' end, 'read pump should notice reader shutdown')
  assert_eq(backend.shutdown_read_reason, 'reader_closed')
end

print('tests/test_stream_pumped.lua: ok')

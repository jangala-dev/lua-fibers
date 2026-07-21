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
local FibersOp = require('fibers.op')
local FibersRuntime = require('fibers.runtime')
local FibersRegion = require('fibers.lifetime.region')
local FibersStream = require('fibers.stream')
local Op = FibersOp
local Stream = FibersStream
local HostHandle = require('fibers.host.handle')

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
    fail((msg or 'status mismatch') .. ': expected ' .. tostring(tag) .. ', got ' .. tostring(st and st.tag))
  end
end
local function assert_not_eq(a, b, msg)
  if a == b then
    fail((msg or 'assert_not_eq failed') .. ': both were ' .. tostring(a))
  end
end

local function drive_until(rt, pred, label)
  for _ = 1, 100 do
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

-- Opening a backend stream is transactional. A losing open starts no reactor fibre.
do
  local backend = HostHandle.fake({ name = 'losing-open-backend' })
  local region = FibersRegion.new('losing-open-region')
  local got
  local st = fibers.try_run(function()
    got = fibers.perform(
      Op.choice(
        Op.always('winner'),
        Stream.open_op(backend, { owner = region, read = true, write = true, name = 'losing-open-stream' })
          :map(function()
            return 'loser'
          end)
      )
    )
  end, { choice_seed = 3 }).runtime_status
  assert_status(st, 'found')
  assert_eq(got, 'winner')
  assert_nil(backend.runtime, 'losing open should not start or bind reactor fibres')
  assert_nil(backend.stream, 'losing open should not attach backend to an uncommitted stream')
end

-- HostHandle Streams expose stable reader and writer capabilities.
do
  local rt = FibersRuntime.new()
  local region = FibersRegion.new('compound-region')
  local backend = HostHandle.fake({ name = 'compound-backend' })
  local stream
  rt:spawn_raw(function()
    stream = rt:perform(
      Stream.open_op(backend, { owner = region, read = true, write = true, name = 'compound-stream' })
    )
  end, 'root')
  assert_status(rt:run(), 'found')
  assert_truthy(stream, 'open_op should return a stream')
  assert_eq(stream.handle, backend, 'HostStream should retain its HostHandle')
  assert_truthy(stream:reader() and stream:writer(), 'stream should expose reader and writer handles')
  assert_eq(stream:reader(), stream:reader(), 'reader handle should be stable')
  assert_eq(stream:writer(), stream:writer(), 'writer handle should be stable')
  assert_truthy(type(stream.read_line_op) == 'function', 'stream should forward reader options')
  assert_truthy(type(stream.write_op) == 'function', 'stream should forward writer options')
end

-- Flow surfaces are capability-specific; looping friendly methods and duplex byte ops are absent.
do
  local a, _b = Stream.memory_pair({ name = 'no-friendly-stream' })
  assert_eq(type(a.read), 'function', 'stream exposes direct performing read')
  assert_eq(type(a.write), 'function', 'stream exposes direct performing write')
  assert_eq(type(a.close), 'function', 'stream exposes direct performing close')
  assert_truthy(type(a.read_line_op) == 'function', 'duplex should forward reader options')
  assert_truthy(type(a.write_op) == 'function', 'duplex should forward writer options')
end

-- All host-backed directions in one runtime share one reactor fibre.
do
  local rt = FibersRuntime.new()
  local region = FibersRegion.new('shared-reactor-region')
  local backend_a = HostHandle.fake({ name = 'shared-reactor-a' })
  local backend_b = HostHandle.fake({ name = 'shared-reactor-b' })
  local stream_a, stream_b
  rt:spawn_raw(function()
    stream_a =
      rt:perform(Stream.open_op(backend_a, { owner = region, read = true, write = true, name = 'shared-a' }))
    stream_b =
      rt:perform(Stream.open_op(backend_b, { owner = region, read = true, write = true, name = 'shared-b' }))
  end, 'root')
  assert_status(rt:run(), 'found')
  assert_truthy(rt.host_reactor, 'runtime should own a host reactor')
  assert_eq(stream_a.reactor, rt.host_reactor)
  assert_eq(stream_b.reactor, rt.host_reactor)
  assert_eq(rt.host_reactor:registration_count(), 4, 'two duplex streams should register four directions')
  assert_nil(stream_a.read_task, 'host stream should allocate no read task')
  assert_nil(stream_a.write_task, 'host stream should allocate no write task')
end

-- Host input enters the stream only through the read reaction committing bytes into
-- the incoming Flow buffer.
do
  local rt = FibersRuntime.new()
  local region = FibersRegion.new('read-region')
  local backend = HostHandle.fake({ name = 'read-backend' })
  local stream, got
  rt:spawn_raw(function()
    stream =
      rt:perform(Stream.open_op(backend, { owner = region, read = true, write = true, name = 'read-stream' }))
    got = rt:perform(stream:reader():read_exactly_op(3))
  end, 'root')
  assert_status(rt:run(), 'found')
  assert_nil(got)
  backend:feed_read('abc')
  drive_until(rt, function()
    return got == 'abc'
  end, 'host read bytes should become stream bytes')
  assert_eq(got, 'abc')
end

-- The read reaction honours input Flow buffer capacity.
do
  local rt = FibersRuntime.new()
  local region = FibersRegion.new('capacity-read-region')
  local backend = HostHandle.fake({ name = 'capacity-read-backend' })
  local stream, first, second
  rt:spawn_raw(function()
    stream = rt:perform(Stream.open_op(backend, {
      owner = region,
      read = true,
      write = true,
      name = 'capacity-read-stream',
      read_capacity = 2,
      read_chunk_size = 4,
    }))
    first = rt:perform(stream:reader():read_exactly_op(2))
    second = rt:perform(stream:reader():read_exactly_op(2))
  end, 'root')
  assert_status(rt:run(), 'found')
  backend:feed_read('abcd')
  drive_until(rt, function()
    return first == 'ab'
  end, 'first capacity-limited read')
  assert_eq(first, 'ab')
  drive_until(rt, function()
    return second == 'cd'
  end, 'second capacity-limited read')
  assert_eq(second, 'cd')
end

-- Writes append to the outgoing queue and the write reaction sends committed bytes to the backend.
do
  local rt = FibersRuntime.new()
  local region = FibersRegion.new('write-region')
  local backend = HostHandle.fake({ name = 'write-backend' })
  local stream, flushed
  rt:spawn_raw(function()
    stream = rt:perform(
      Stream.open_op(backend, { owner = region, read = true, write = true, name = 'write-stream' })
    )
    rt:perform(stream:writer():write_op('abc'))
    flushed = rt:perform(stream:writer():flush_op())
  end, 'root')
  drive_until(rt, function()
    return flushed == true
  end, 'write should flush')
  assert_eq(backend:written(), 'abc')
end

-- Losing writes to a host-backed stream discharge nothing to the backend.
do
  local rt = FibersRuntime.new({ choice_seed = 3 })
  local region = FibersRegion.new('losing-write-region')
  local backend = HostHandle.fake({ name = 'losing-write-backend' })
  local stream, got
  rt:spawn_raw(function()
    stream = rt:perform(
      Stream.open_op(backend, { owner = region, read = true, write = true, name = 'losing-write-stream' })
    )
    got = rt:perform(Op.choice(
      Op.always('winner'),
      stream:writer():write_op('abc'):map(function()
        return 'loser'
      end)
    ))
  end, 'root')
  drive_until(rt, function()
    return got == 'winner'
  end, 'losing write choice')
  assert_eq(backend:written(), '')
end

-- Partial host writes preserve ordering and are acknowledged exactly.
do
  local rt = FibersRuntime.new()
  local region = FibersRegion.new('partial-write-region')
  local backend = HostHandle.fake({ name = 'partial-write-backend', write_chunk_size = 2 })
  local stream, flushed
  rt:spawn_raw(function()
    stream = rt:perform(
      Stream.open_op(
        backend,
        { owner = region, read = true, write = true, name = 'partial-write-stream', write_chunk_size = 6 }
      )
    )
    rt:perform(stream:writer():write_op('abcdef'))
    flushed = rt:perform(stream:writer():flush_op())
  end, 'root')
  drive_until(rt, function()
    return flushed == true
  end, 'partial writes should eventually flush')
  assert_eq(backend:written(), 'abcdef')
end

-- Would-block preserves an in-flight lease; flush waits until the lease is acknowledged.
do
  local rt = FibersRuntime.new()
  local region = FibersRegion.new('would-block-region')
  local backend = HostHandle.fake({
    name = 'would-block-backend',
    readiness = 'manual',
    initial_writable = false,
    write_blocked = true,
  })
  local stream, flushed
  rt:spawn_raw(function()
    stream = rt:perform(
      Stream.open_op(backend, { owner = region, read = true, write = true, name = 'would-block-stream' })
    )
    rt:perform(stream:writer():write_op('abc'))
    flushed = rt:perform(stream:writer():flush_op())
  end, 'root')
  -- A stale writable hint lets the reactor reserve bytes before the authoritative
  -- host write reports would_block.
  backend:mark_writable()
  for _ = 1, 10 do
    if
      stream
      and Inspect.first_lease_bytes(stream:writer().flow) ~= nil
      and Inspect.first_lease_bytes(stream:writer().flow) ~= ''
    then
      break
    end
    rt:run()
  end
  assert_truthy(
    stream
      and Inspect.first_lease_bytes(stream:writer().flow) ~= nil
      and Inspect.first_lease_bytes(stream:writer().flow) ~= '',
    'write reaction should hold an in-flight lease while blocked'
  )
  assert_nil(flushed, 'flush should wait while bytes are in flight')
  assert_eq(backend:written(), '')
  backend:unblock_writes()
  drive_until(rt, function()
    return flushed == true
  end, 'unblocked write should flush')
  assert_eq(backend:written(), 'abc')
end

-- EOF becomes committed stream state.
do
  local rt = FibersRuntime.new()
  local region = FibersRegion.new('eof-region')
  local backend = HostHandle.fake({ name = 'eof-backend' })
  local stream, first, second, err
  rt:spawn_raw(function()
    stream =
      rt:perform(Stream.open_op(backend, { owner = region, read = true, write = true, name = 'eof-stream' }))
    first = rt:perform(stream:reader():read_exactly_op(3))
    second, err = rt:perform(stream:reader():read_some_op(1))
  end, 'root')
  assert_status(rt:run(), 'found')
  backend:feed_read('abc')
  backend:feed_eof()
  drive_until(rt, function()
    return err == 'eof'
  end, 'EOF should reach stream')
  assert_eq(first, 'abc')
  assert_nil(second)
  assert_eq(err, 'eof')
end

-- shutdown_write drains pending/in-flight data before shutting down the backend write side.
do
  local rt = FibersRuntime.new()
  local region = FibersRegion.new('shutdown-write-region')
  local backend = HostHandle.fake({ name = 'shutdown-write-backend', write_blocked = true })
  local stream, done
  rt:spawn_raw(function()
    stream = rt:perform(
      Stream.open_op(backend, { owner = region, read = true, write = true, name = 'shutdown-write-stream' })
    )
    rt:perform(stream:writer():write_op('abc'))
    rt:perform(stream:shutdown_write_op())
    done = rt:perform(stream:writer():flush_op())
  end, 'root')
  for _ = 1, 10 do
    if
      stream
      and Inspect.first_lease_bytes(stream:writer().flow) ~= nil
      and Inspect.first_lease_bytes(stream:writer().flow) ~= ''
    then
      break
    end
    rt:run()
  end
  assert_nil(backend.shutdown_write_reason, 'backend write should not shut down before draining')
  backend:unblock_writes()
  drive_until(rt, function()
    return done == true and backend.shutdown_write_reason ~= nil
  end, 'shutdown should happen after drain')
  assert_eq(backend:written(), 'abc')
end

-- Host write errors become committed stream write errors.
do
  local rt = FibersRuntime.new()
  local region = FibersRegion.new('write-error-region')
  local backend = HostHandle.fake({ name = 'write-error-backend' })
  backend:fail_writes('connection_reset')
  local stream, flushed, flush_err, n, err
  rt:spawn_raw(function()
    stream = rt:perform(
      Stream.open_op(backend, { owner = region, read = true, write = true, name = 'write-error-stream' })
    )
    rt:perform(stream:writer():write_op('abc'))
    flushed, flush_err = rt:perform(stream:writer():flush_op())
    n, err = rt:perform(stream:writer():write_op('d'))
  end, 'root')
  drive_until(rt, function()
    return err == 'connection_reset'
  end, 'write error should commit')
  assert_nil(flushed)
  assert_eq(flush_err, 'connection_reset')
  assert_nil(n)
  assert_eq(err, 'connection_reset')
end

-- A reactor lease keeps byte capacity reserved until the host acknowledges it.
do
  local rt = FibersRuntime.new()
  local region = FibersRegion.new('lease-capacity-region')
  local backend = HostHandle.fake({
    name = 'lease-capacity-backend',
    readiness = 'manual',
    initial_writable = false,
    write_blocked = true,
  })
  local stream, second_done, flushed
  rt:spawn_raw(function()
    stream = rt:perform(
      Stream.open_op(
        backend,
        { owner = region, read = true, write = true, name = 'lease-capacity-stream', write_capacity = 3 }
      )
    )
    rt:perform(stream:writer():write_op('abc'))
    flushed = rt:perform(stream:writer():flush_op())
  end, 'writer1')
  backend:mark_writable()
  for _ = 1, 10 do
    if
      stream
      and Inspect.first_lease_bytes(stream:writer().flow) ~= nil
      and Inspect.first_lease_bytes(stream:writer().flow) ~= ''
    then
      break
    end
    rt:run()
  end
  assert_eq(
    Inspect.first_lease_bytes(stream:writer().flow),
    'abc',
    'reactor should have leased the first write'
  )
  assert_eq(
    (
      stream:writer().flow.capacity
      - (#(stream:writer().flow.data or '') + Inspect.leased_bytes(stream:writer().flow))
    ),
    0,
    'leased bytes should still reserve capacity'
  )
  rt:spawn_raw(function()
    second_done = rt:perform(stream:writer():write_op('d'))
  end, 'writer2')
  assert_status(rt:run(), 'pending')
  assert_nil(second_done, 'second write should wait while leased bytes hold capacity')
  assert_nil(flushed, 'flush should wait while lease is blocked')
  backend:unblock_writes()
  drive_until(rt, function()
    return second_done == 1 and flushed == true
  end, 'acknowledged lease should release capacity')
  assert_eq(backend:written(), 'abcd')
end

-- The read reaction notices reader shutdown even while backend readability never arrives.
do
  local rt = FibersRuntime.new()
  local region = FibersRegion.new('blocked-read-close-region')
  local backend = HostHandle.fake({ name = 'blocked-read-close-backend', read_blocked = true })
  local stream
  rt:spawn_raw(function()
    stream = rt:perform(
      Stream.open_op(
        backend,
        { owner = region, read = true, write = true, name = 'blocked-read-close-stream' }
      )
    )
  end, 'open-blocked-read')
  assert_status(rt:run(), 'found')
  rt:spawn_raw(function()
    rt:perform(stream:shutdown_read_op('close_reader'))
  end, 'close-reader')
  drive_until(rt, function()
    return backend.shutdown_read_reason == 'close_reader'
  end, 'read reaction should notice reader shutdown')
  assert_eq(backend.shutdown_read_reason, 'close_reader')
end

-- Closing a host stream retires both reactions, closes the backend once and
-- allows the shared reactor fibre to stop when no registrations remain.
do
  local rt = FibersRuntime.new()
  local region = FibersRegion.new('reactor-retirement-region')
  local backend = HostHandle.fake({ name = 'reactor-retirement-backend', read_blocked = true })
  local stream, closed
  rt:spawn_raw(function()
    stream = rt:perform(
      Stream.open_op(
        backend,
        { owner = region, read = true, write = true, name = 'reactor-retirement-stream' }
      )
    )
    rt:perform(stream:abort_op('finished'))
    closed = rt:perform(stream:closed_op())
  end, 'root')
  drive_until(rt, function()
    return closed == true and rt.host_reactor and rt.host_reactor.running == false
  end, 'stream closure should retire the reactor registrations')
  assert_eq(rt.host_reactor:registration_count(), 0)
  assert_eq(backend.closed_reason, 'finished')
  assert_eq(backend.close_count, 1, 'shared backend should close exactly once')
  assert_eq(stream.read_registration.retired, true)
  assert_eq(stream.write_registration.retired, true)
end

-- Directional host Streams allocate only the supported Flow and reaction.
do
  local rt = FibersRuntime.new()
  local region = FibersRegion.new('directional-region')
  local read_backend = HostHandle.fake({ name = 'directional-reader' })
  local write_backend = HostHandle.fake({ name = 'directional-writer' })
  local reader, writer
  rt:spawn_raw(function()
    reader = rt:perform(Stream.open_op(read_backend, {
      owner = region,
      name = 'reader-only',
      read = true,
      write = false,
    }))
    writer = rt:perform(Stream.open_op(write_backend, {
      owner = region,
      name = 'writer-only',
      read = false,
      write = true,
    }))
  end, 'root')
  assert_status(rt:run(), 'found')
  assert_truthy(reader:is_readable())
  assert_eq(reader:is_writable(), false)
  assert_truthy(reader:reader())
  assert_nil(reader:writer())
  assert_truthy(writer:is_writable())
  assert_eq(writer:is_readable(), false)
  assert_truthy(writer:writer())
  assert_nil(writer:reader())
  assert_eq(rt.host_reactor:registration_count(), 2)
  rt:spawn_raw(function()
    rt:perform(reader:abort_op('test complete'))
    rt:perform(writer:abort_op('test complete'))
  end, 'close-directional')
  drive_until(rt, function()
    return rt.host_reactor:registration_count() == 0
  end, 'directional streams should retire')
end

-- Nested scope settlement waits for completed Stream closure before returning.
do
  local backend = HostHandle.fake({ name = 'nested-settlement-backend' })
  fibers.run(function()
    fibers.scope(function()
      fibers.perform(
        Stream.open_op(backend, { read = true, write = true, name = 'nested-settlement-stream' })
      )
    end)
    assert_eq(backend.close_count, 1, 'nested scope should wait for backend closure')
  end)
end

-- Unsupported directions are absent and direct use is a programming error.
do
  local rt = FibersRuntime.new()
  local region = FibersRegion.new('direction-errors-region')
  local backend = HostHandle.fake({ name = 'direction-errors-backend' })
  local reader
  rt:spawn_raw(function()
    reader = rt:perform(Stream.open_op(backend, {
      owner = region,
      name = 'direction-errors-reader',
      read = true,
      write = false,
    }))
  end, 'root')
  assert_status(rt:run(), 'found')
  local ok, err = pcall(function()
    reader:write_op('no')
  end)
  assert_eq(ok, false)
  assert_truthy(tostring(err):find('not writable', 1, true))
  rt:spawn_raw(function()
    rt:perform(reader:abort_op('test complete'))
  end, 'close')
  drive_until(rt, function()
    return rt.host_reactor:registration_count() == 0
  end)
end

-- Backend close errors are retained and reported by closed_op.
do
  local rt = FibersRuntime.new()
  local region = FibersRegion.new('close-error-region')
  local backend = HostHandle.fake({ name = 'close-error-backend' })
  function backend:close(reason)
    self.close_count = self.close_count + 1
    self.closed_reason = reason
    return nil, 'close_failed'
  end
  local stream, closed, close_err
  rt:spawn_raw(function()
    stream = rt:perform(Stream.open_op(backend, {
      owner = region,
      name = 'close-error-stream',
      read = false,
      write = true,
    }))
    rt:perform(stream:abort_op('done'))
    closed, close_err = rt:perform(stream:closed_op())
  end, 'root')
  drive_until(rt, function()
    return close_err ~= nil
  end, 'close error should be observable')
  assert_nil(closed)
  assert_eq(close_err, 'close_failed')
end

-- Abort retirement discards pending output and completes even when the host can
-- never accept the retained bytes. Drain remains the explicit graceful mode.
do
  local rt = FibersRuntime.new()
  local region = FibersRegion.new('abort-write-region')
  local backend = HostHandle.fake({
    name = 'abort-write-backend',
    write_blocked = true,
    initial_writable = false,
  })
  local stream, closed, close_err
  rt:spawn_raw(function()
    stream = rt:perform(Stream.open_op(backend, {
      owner = region,
      name = 'abort-write-stream',
      read = false,
      write = true,
    }))
    rt:perform(stream:write_op('never-written'))
    rt:perform(stream:abort_write_op('cancelled'))
    closed, close_err = rt:perform(stream:closed_op())
  end, 'abort-writer')
  drive_until(rt, function()
    return closed == true
  end, 'abort shutdown should complete without host writability')
  assert_nil(close_err)
  assert_eq(backend:written(), '')
  assert_eq(backend.shutdown_write_reason, 'cancelled')
  assert_eq(backend.close_count, 1)
end

-- Backend capabilities are validated before ownership or registrations commit.
do
  local region = FibersRegion.new('backend-contract-region')
  local ok, err = pcall(function()
    Stream.open_op(
      require('fibers.host.handle').new({
        name = 'missing-close',
        key = 'missing-close-key',
        read = function()
          return nil, 'would_block'
        end,
      }),
      { owner = region, read = true, write = false }
    )
  end)
  assert_eq(ok, false)
  assert_truthy(tostring(err):find('requires close', 1, true))

  ok, err = pcall(function()
    Stream.open_op(
      require('fibers.host.handle').new({
        name = 'missing-read',
        key = 'missing-read-key',
        close = function()
          return true
        end,
      }),
      { owner = region, read = true, write = false }
    )
  end)
  assert_eq(ok, false)
  assert_truthy(tostring(err):find('requires read', 1, true))

  local wrapped = require('fibers.host.handle').new({
    name = 'wrapped-missing-close',
    key = 'wrapped-missing-close-key',
    read = function()
      return nil, 'would_block'
    end,
  })
  ok, err = pcall(function()
    Stream.open_op(wrapped, { owner = region, read = true, write = false })
  end)
  assert_eq(ok, false)
  assert_truthy(tostring(err):find('requires close', 1, true))
end

-- A backend readiness_key method may return distinct direction keys.
do
  local rt = FibersRuntime.new()
  local region = FibersRegion.new('direction-key-region')
  local backend = require('fibers.host.handle').new({
    name = 'direction-key-backend',
    key = { read = 'direction-read-key', write = 'direction-write-key' },
    read = function()
      return nil, 'would_block'
    end,
    write = function(_self, bytes)
      return #bytes
    end,
    close = function()
      return true
    end,
  })
  local stream
  rt:spawn_raw(function()
    stream = rt:perform(Stream.open_op(backend, {
      owner = region,
      name = 'direction-key-stream',
      read = true,
      write = true,
    }))
  end, 'direction-key-open')
  assert_status(rt:run(), 'found')
  assert_eq(stream.read_registration.key, 'direction-read-key')
  assert_eq(stream.write_registration.key, 'direction-write-key')
  rt:spawn_raw(function()
    rt:perform(stream:close_op('done'))
    rt:perform(stream:closed_op())
  end, 'direction-key-close')
  drive_until(rt, function()
    return backend.closed == true or rt.host_reactor:registration_count() == 0
  end)
end

local function run_read_contract_case(name, read_result, expected_bytes, expected_err)
  local rt = FibersRuntime.new()
  local region = FibersRegion.new(name .. '-region')
  local backend = HostHandle.fake({
    name = name .. '-backend',
    readiness = 'manual',
    initial_readable = true,
  })
  function backend:read(_max)
    return read_result()
  end
  local bytes, err
  rt:spawn_raw(function()
    local stream = rt:perform(Stream.open_op(backend, {
      owner = region,
      name = name .. '-stream',
      read = true,
      write = false,
      read_chunk_size = 16,
    }))
    bytes, err = rt:perform(stream:read_some_op(16))
  end, name)
  drive_until(rt, function()
    return bytes ~= nil or err ~= nil
  end, name .. ' should produce a terminal read result')
  assert_eq(bytes, expected_bytes, name .. ' bytes')
  assert_eq(err, expected_err, name .. ' error')
end

-- EOF may accompany an empty or final non-empty byte string. Empty success
-- without EOF/would_block, mixed data with non-EOF error, and non-string data
-- are backend protocol errors.
do
  run_read_contract_case('empty-eof', function()
    return '', 'eof'
  end, nil, 'eof')

  local calls = 0
  run_read_contract_case('data-eof', function()
    calls = calls + 1
    if calls == 1 then
      return 'tail', 'eof'
    end
    return nil, 'would_block'
  end, 'tail', nil)

  run_read_contract_case('empty-success', function()
    return ''
  end, nil, 'backend_protocol_error')

  run_read_contract_case('mixed-error', function()
    return 'x', 'connection_reset'
  end, nil, 'backend_protocol_error')

  run_read_contract_case('nil-success', function()
    return nil
  end, nil, 'backend_protocol_error')

  run_read_contract_case('oversized', function()
    return string.rep('x', 32)
  end, nil, 'backend_protocol_error')

  run_read_contract_case('non-string', function()
    return 42
  end, nil, 'backend_protocol_error')
end

-- Stream ownership movement uses the general lifetime API; Stream exposes no transfer aliases.
do
  local a = Stream.memory_pair({ name = 'no-endpoint-transfer' })
  assert_nil(a.transfer_reader_op)
  assert_nil(a.transfer_writer_op)
  assert_nil(a.transfer_op)
end

-- The version 1 Stream module and instance surface have no constructor or
-- lifecycle aliases.
do
  assert_nil(Stream.open_backend_op)
  assert_nil(Stream.open_backend_in_op)
  assert_nil(Stream.open_handle_op)
  assert_nil(Stream.open_handle_in_op)
  assert_nil(Stream.open_reader_backend_op)
  assert_nil(Stream.open_writer_backend_op)
  assert_nil(Stream.open_duplex_backend_op)
  assert_nil(Stream.Duplex)
  assert_nil(Stream.HostStream)
  assert_nil(Stream.backend)

  local a = Stream.memory_pair({ name = 'public-stream-surface' })
  assert_nil(a.shutdown_op)
  assert_nil(a.exit_op)
  assert_nil(a.transfer_op)
  assert_nil(a.read_flow_handle)
  assert_nil(a.write_flow_handle)
  assert_truthy(type(a.close_op) == 'function')
  assert_truthy(type(a.abort_op) == 'function')
  assert_truthy(type(a.abort_write_op) == 'function')
end

-- Host Stream construction requires explicit capabilities and rejects legacy
-- option spellings.
do
  local backend = HostHandle.fake({ name = 'explicit-stream-options' })
  local region = FibersRegion.new('explicit-stream-options-region')
  local ok, err = pcall(function()
    Stream.open_op(backend, { owner = region, name = 'missing-directions' })
  end)
  assert_eq(ok, false)
  assert_truthy(tostring(err):find('explicit boolean', 1, true))

  ok, err = pcall(function()
    Stream.open_op(backend, {
      owner = region,
      read = true,
      write = true,
      capacity = 32,
    })
  end)
  assert_eq(ok, false)
  assert_truthy(tostring(err):find('does not accept capacity', 1, true))
end

print('tests/embedding/test_stream_reactor.lua: ok')

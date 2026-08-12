package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')
local Inspect = require('tests.support.flow_inspect')

local fibers = require('fibers')
local FakeHandle = require('tests.support.fake_handle')
local FibersOp = require('fibers.op')
local FibersRuntime = require('fibers.runtime')
local FibersScope = require('fibers.scope')
local FibersStream = require('fibers.io.stream')
local Op = FibersOp
local Stream = FibersStream
local HostHandle = require('fibers.io.handle')

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

-- Opening a backend stream is transactional. A losing open starts no reactor fiber.
do
  local backend = FakeHandle.new({ label = 'losing-open-backend' })
  local owner = FibersScope.new():label('losing-open-owner')
  local got
  local st = fibers.try_run(function()
    got = fibers.perform(
      Op.choice(
        Op.always('winner'),
        Stream.open_op(backend, { scope = owner, read = true, write = true, label = 'losing-open-stream' })
          :map(function()
            return 'loser'
          end)
      )
    )
  end, { choice_seed = 3 }).runtime_status
  assert_status(st, 'found')
  assert_eq(got, 'winner')
  assert_nil(backend._runtime, 'losing open should not start or bind reactor fibers')
  assert_nil(backend._stream, 'losing open should not attach backend to an uncommitted stream')
end

-- HostHandle Streams expose stable reader and writer capabilities.
do
  local rt = FibersRuntime.new()
  local owner = FibersScope.new():label('compound-owner')
  local backend = FakeHandle.new({ label = 'compound-backend' })
  local stream
  rt:spawn_raw(function()
    stream = rt:perform(
      Stream.open_op(backend, { scope = owner, read = true, write = true, label = 'compound-stream' })
    )
  end):label('root')
  assert_status(rt:run(), 'found')
  assert_truthy(stream, 'open_op should return a stream')
  assert_eq(stream._handle, backend, 'HostStream should retain its HostHandle')
  assert_truthy(stream:reader() and stream:writer(), 'stream should expose reader and writer handles')
  assert_eq(stream:reader(), stream:reader(), 'reader handle should be stable')
  assert_eq(stream:writer(), stream:writer(), 'writer handle should be stable')
  assert_truthy(type(stream.read_line_op) == 'function', 'stream should forward reader options')
  assert_truthy(type(stream.write_op) == 'function', 'stream should forward writer options')
end

-- Flow surfaces are capability-specific; looping friendly methods and duplex byte ops are absent.
do
  local a, _b = Stream.memory_pair({ label = 'no-friendly-stream' })
  assert_eq(a.read, nil, 'stream does not expose Lua-file-style read compatibility')
  assert_eq(type(a.read_some), 'function', 'stream exposes direct performing read_some')
  assert_eq(type(a.write), 'function', 'stream exposes direct performing write')
  assert_eq(type(a.close), 'function', 'stream exposes direct performing close')
  assert_truthy(type(a.read_line_op) == 'function', 'duplex should forward reader options')
  assert_truthy(type(a.write_op) == 'function', 'duplex should forward writer options')
end

-- All host-backed directions in one runtime share one reactor fiber.
do
  local rt = FibersRuntime.new()
  local owner = FibersScope.new():label('shared-reactor-owner')
  local backend_a = FakeHandle.new({ label = 'shared-reactor-a' })
  local backend_b = FakeHandle.new({ label = 'shared-reactor-b' })
  local stream_a, stream_b
  rt:spawn_raw(function()
    stream_a =
      rt:perform(Stream.open_op(backend_a, { scope = owner, read = true, write = true, label = 'shared-a' }))
    stream_b =
      rt:perform(Stream.open_op(backend_b, { scope = owner, read = true, write = true, label = 'shared-b' }))
  end):label('root')
  assert_status(rt:run(), 'found')
  assert_truthy(rt.host_reactor, 'runtime should own a host reactor')
  assert_eq(stream_a._read_registration.reactor, rt.host_reactor)
  assert_eq(stream_b._read_registration.reactor, rt.host_reactor)
  assert_eq(rt.host_reactor:_registration_count(), 4, 'two duplex streams should register four directions')
  assert_nil(stream_a.read_task, 'host stream should allocate no read task')
  assert_nil(stream_a.write_task, 'host stream should allocate no write task')
end

-- Host input enters the stream only through the read reaction committing bytes into
-- the incoming Flow buffer.
do
  local rt = FibersRuntime.new()
  local owner = FibersScope.new():label('read-owner')
  local backend = FakeHandle.new({ label = 'read-backend' })
  local stream, got
  rt:spawn_raw(function()
    stream =
      rt:perform(Stream.open_op(backend, { scope = owner, read = true, write = true, label = 'read-stream' }))
    got = rt:perform(stream:reader():read_exactly_op(3))
  end):label('root')
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
  local owner = FibersScope.new():label('capacity-read-owner')
  local backend = FakeHandle.new({ label = 'capacity-read-backend' })
  local stream, first, second
  rt:spawn_raw(function()
    stream = rt:perform(Stream.open_op(backend, {
      scope = owner,
      read = true,
      write = true,
      label = 'capacity-read-stream',
      read_capacity = 2,
      read_chunk_size = 4,
    }))
    first = rt:perform(stream:reader():read_exactly_op(2))
    second = rt:perform(stream:reader():read_exactly_op(2))
  end):label('root')
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
  local owner = FibersScope.new():label('write-owner')
  local backend = FakeHandle.new({ label = 'write-backend' })
  local stream, flushed
  rt:spawn_raw(function()
    stream = rt:perform(
      Stream.open_op(backend, { scope = owner, read = true, write = true, label = 'write-stream' })
    )
    rt:perform(stream:writer():write_op('abc'))
    flushed = rt:perform(stream:writer():flush_op())
  end):label('root')
  drive_until(rt, function()
    return flushed == true
  end, 'write should flush')
  assert_eq(backend:written(), 'abc')
end

-- Losing writes to a host-backed stream discharge nothing to the backend.
do
  local rt = FibersRuntime.new({ choice_seed = 3 })
  local owner = FibersScope.new():label('losing-write-owner')
  local backend = FakeHandle.new({ label = 'losing-write-backend' })
  local stream, got
  rt:spawn_raw(function()
    stream = rt:perform(
      Stream.open_op(backend, { scope = owner, read = true, write = true, label = 'losing-write-stream' })
    )
    got = rt:perform(Op.choice(
      Op.always('winner'),
      stream:writer():write_op('abc'):map(function()
        return 'loser'
      end)
    ))
  end):label('root')
  drive_until(rt, function()
    return got == 'winner'
  end, 'losing write choice')
  assert_eq(backend:written(), '')
end

-- Partial host writes preserve ordering and are acknowledged exactly.
do
  local rt = FibersRuntime.new()
  local owner = FibersScope.new():label('partial-write-owner')
  local backend = FakeHandle.new({ label = 'partial-write-backend', write_chunk_size = 2 })
  local stream, flushed
  rt:spawn_raw(function()
    stream = rt:perform(
      Stream.open_op(
        backend,
        { scope = owner, read = true, write = true, label = 'partial-write-stream', write_chunk_size = 6 }
      )
    )
    rt:perform(stream:writer():write_op('abcdef'))
    flushed = rt:perform(stream:writer():flush_op())
  end):label('root')
  drive_until(rt, function()
    return flushed == true
  end, 'partial writes should eventually flush')
  assert_eq(backend:written(), 'abcdef')
end

-- Would-block preserves an in-flight lease; flush waits until the lease is acknowledged.
do
  local rt = FibersRuntime.new()
  local owner = FibersScope.new():label('would-block-owner')
  local backend = FakeHandle.new({
    label = 'would-block-backend',
    readiness = 'manual',
    initial_writable = false,
    write_blocked = true,
  })
  local stream, flushed
  rt:spawn_raw(function()
    stream = rt:perform(
      Stream.open_op(backend, { scope = owner, read = true, write = true, label = 'would-block-stream' })
    )
    rt:perform(stream:writer():write_op('abc'))
    flushed = rt:perform(stream:writer():flush_op())
  end):label('root')
  -- A stale writable hint lets the reactor reserve bytes before the authoritative
  -- host write reports would_block.
  backend:mark_writable()
  for _ = 1, 10 do
    if
      stream
      and Inspect.first_lease_bytes(stream:writer()._flow) ~= nil
      and Inspect.first_lease_bytes(stream:writer()._flow) ~= ''
    then
      break
    end
    rt:run()
  end
  assert_truthy(
    stream
      and Inspect.first_lease_bytes(stream:writer()._flow) ~= nil
      and Inspect.first_lease_bytes(stream:writer()._flow) ~= '',
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
  local owner = FibersScope.new():label('eof-owner')
  local backend = FakeHandle.new({ label = 'eof-backend' })
  local stream, first, second, err
  rt:spawn_raw(function()
    stream =
      rt:perform(Stream.open_op(backend, { scope = owner, read = true, write = true, label = 'eof-stream' }))
    first = rt:perform(stream:reader():read_exactly_op(3))
    second, err = rt:perform(stream:reader():read_some_op(1))
  end):label('root')
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
  local owner = FibersScope.new():label('shutdown-write-owner')
  local backend = FakeHandle.new({ label = 'shutdown-write-backend', write_blocked = true })
  local stream, done
  rt:spawn_raw(function()
    stream = rt:perform(
      Stream.open_op(backend, { scope = owner, read = true, write = true, label = 'shutdown-write-stream' })
    )
    rt:perform(stream:writer():write_op('abc'))
    rt:perform(stream:shutdown_write_op())
    done = rt:perform(stream:writer():flush_op())
  end):label('root')
  for _ = 1, 10 do
    if
      stream
      and Inspect.first_lease_bytes(stream:writer()._flow) ~= nil
      and Inspect.first_lease_bytes(stream:writer()._flow) ~= ''
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
  local owner = FibersScope.new():label('write-error-owner')
  local backend = FakeHandle.new({ label = 'write-error-backend' })
  backend:fail_writes('connection_reset')
  local stream, flushed, flush_err, n, err
  rt:spawn_raw(function()
    stream = rt:perform(
      Stream.open_op(backend, { scope = owner, read = true, write = true, label = 'write-error-stream' })
    )
    rt:perform(stream:writer():write_op('abc'))
    flushed, flush_err = rt:perform(stream:writer():flush_op())
    n, err = rt:perform(stream:writer():write_op('d'))
  end):label('root')
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
  local owner = FibersScope.new():label('lease-capacity-owner')
  local backend = FakeHandle.new({
    label = 'lease-capacity-backend',
    readiness = 'manual',
    initial_writable = false,
    write_blocked = true,
  })
  local stream, second_done, flushed
  rt:spawn_raw(function()
    stream = rt:perform(
      Stream.open_op(
        backend,
        { scope = owner, read = true, write = true, label = 'lease-capacity-stream', write_capacity = 3 }
      )
    )
    rt:perform(stream:writer():write_op('abc'))
    flushed = rt:perform(stream:writer():flush_op())
  end):label('writer1')
  backend:mark_writable()
  for _ = 1, 10 do
    if
      stream
      and Inspect.first_lease_bytes(stream:writer()._flow) ~= nil
      and Inspect.first_lease_bytes(stream:writer()._flow) ~= ''
    then
      break
    end
    rt:run()
  end
  assert_eq(
    Inspect.first_lease_bytes(stream:writer()._flow),
    'abc',
    'reactor should have leased the first write'
  )
  assert_eq(
    (
      stream:writer()._flow._capacity
      - (#(stream:writer()._flow.data or '') + Inspect.leased_bytes(stream:writer()._flow))
    ),
    0,
    'leased bytes should still reserve capacity'
  )
  rt:spawn_raw(function()
    second_done = rt:perform(stream:writer():write_op('d'))
  end):label('writer2')
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
  local owner = FibersScope.new():label('blocked-read-close-owner')
  local backend = FakeHandle.new({ label = 'blocked-read-close-backend', read_blocked = true })
  local stream
  rt:spawn_raw(function()
    stream = rt:perform(
      Stream.open_op(
        backend,
        { scope = owner, read = true, write = true, label = 'blocked-read-close-stream' }
      )
    )
  end):label('open-blocked-read')
  assert_status(rt:run(), 'found')
  rt:spawn_raw(function()
    rt:perform(stream:shutdown_read_op('close_reader'))
  end):label('close-reader')
  drive_until(rt, function()
    return backend.shutdown_read_reason == 'close_reader'
  end, 'read reaction should notice reader shutdown')
  assert_eq(backend.shutdown_read_reason, 'close_reader')
end

-- Closing a host stream retires both reactions, closes the backend once and
-- allows the shared reactor fiber to stop when no registrations remain.
do
  local rt = FibersRuntime.new()
  local owner = FibersScope.new():label('reactor-retirement-owner')
  local backend = FakeHandle.new({ label = 'reactor-retirement-backend', read_blocked = true })
  local stream, closed
  rt:spawn_raw(function()
    stream = rt:perform(
      Stream.open_op(
        backend,
        { scope = owner, read = true, write = true, label = 'reactor-retirement-stream' }
      )
    )
    rt:perform(stream:request_abort_op('finished')); rt:perform(stream:closed_op())
    closed = rt:perform(stream:closed_op())
  end):label('root')
  drive_until(rt, function()
    return closed == true and rt.host_reactor and rt.host_reactor.running == false
  end, 'stream closure should retire the reactor registrations')
  assert_eq(rt.host_reactor:_registration_count(), 0)
  assert_eq(backend.closed_reason, 'finished')
  assert_eq(backend.close_count, 1, 'shared backend should close exactly once')
  assert_eq(stream._read_registration.retired, true)
  assert_eq(stream._write_registration.retired, true)
end

-- Directional host Streams allocate only the supported Flow and reaction.
do
  local rt = FibersRuntime.new()
  local owner = FibersScope.new():label('directional-owner')
  local read_backend = FakeHandle.new({ label = 'directional-reader' })
  local write_backend = FakeHandle.new({ label = 'directional-writer' })
  local reader, writer
  rt:spawn_raw(function()
    reader = rt:perform(Stream.open_op(read_backend, {
      scope = owner,
      label = 'reader-only',
      read = true,
      write = false,
    }))
    writer = rt:perform(Stream.open_op(write_backend, {
      scope = owner,
      label = 'writer-only',
      read = false,
      write = true,
    }))
  end):label('root')
  assert_status(rt:run(), 'found')
  assert_truthy(reader:is_readable())
  assert_eq(reader:is_writable(), false)
  assert_truthy(reader:reader())
  assert_nil(reader:writer())
  assert_truthy(writer:is_writable())
  assert_eq(writer:is_readable(), false)
  assert_truthy(writer:writer())
  assert_nil(writer:reader())
  assert_eq(rt.host_reactor:_registration_count(), 2)
  rt:spawn_raw(function()
    rt:perform(reader:request_abort_op('test complete')); rt:perform(reader:closed_op())
    rt:perform(writer:request_abort_op('test complete')); rt:perform(writer:closed_op())
  end):label('close-directional')
  drive_until(rt, function()
    return rt.host_reactor:_registration_count() == 0
  end, 'directional streams should retire')
end

-- Nested Scope Closure waits for completed Stream closure before returning.
do
  local backend = FakeHandle.new({ label = 'nested-Closure-backend' })
  fibers.run(function()
    fibers.scope(function()
      fibers.perform(
        Stream.open_op(backend, { read = true, write = true, label = 'nested-Closure-stream' })
      )
    end)
    assert_eq(backend.close_count, 1, 'nested scope should wait for backend closure')
  end)
end

-- Unsupported directions are absent and direct use is a programming error.
do
  local rt = FibersRuntime.new()
  local owner = FibersScope.new():label('direction-errors-owner')
  local backend = FakeHandle.new({ label = 'direction-errors-backend' })
  local reader
  rt:spawn_raw(function()
    reader = rt:perform(Stream.open_op(backend, {
      scope = owner,
      label = 'direction-errors-reader',
      read = true,
      write = false,
    }))
  end):label('root')
  assert_status(rt:run(), 'found')
  local ok, err = pcall(function()
    reader:write_op('no')
  end)
  assert_eq(ok, false)
  assert_truthy(tostring(err):find('not writable', 1, true))
  rt:spawn_raw(function()
    rt:perform(reader:request_abort_op('test complete')); rt:perform(reader:closed_op())
  end):label('close')
  drive_until(rt, function()
    return rt.host_reactor:_registration_count() == 0
  end)
end

-- Backend close errors are retained and reported by closed_op.
do
  local rt = FibersRuntime.new()
  local owner = FibersScope.new():label('close-error-owner')
  local backend = FakeHandle.new({ label = 'close-error-backend' })
  function backend:close(reason)
    self.close_count = self.close_count + 1
    self.closed_reason = reason
    return nil, 'close_failed'
  end
  local stream, closed, close_err
  rt:spawn_raw(function()
    stream = rt:perform(Stream.open_op(backend, {
      scope = owner,
      label = 'close-error-stream',
      read = false,
      write = true,
    }))
    rt:perform(stream:request_abort_op('done')); rt:perform(stream:closed_op())
    closed, close_err = rt:perform(stream:closed_op())
  end):label('root')
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
  local owner = FibersScope.new():label('abort-write-owner')
  local backend = FakeHandle.new({
    label = 'abort-write-backend',
    write_blocked = true,
    initial_writable = false,
  })
  local stream, closed, close_err
  rt:spawn_raw(function()
    stream = rt:perform(Stream.open_op(backend, {
      scope = owner,
      label = 'abort-write-stream',
      read = false,
      write = true,
    }))
    rt:perform(stream:write_op('never-written'))
    rt:perform(stream:abort_write_op('cancelled'))
    closed, close_err = rt:perform(stream:closed_op())
  end):label('abort-writer')
  drive_until(rt, function()
    return closed == true
  end, 'abort shutdown should complete without host writability')
  assert_nil(close_err)
  assert_eq(backend:written(), '')
  assert_eq(backend.shutdown_write_reason, 'cancelled')
  assert_eq(backend.close_count, 1)
end

-- Backend contracts are validated before ownership or registrations commit.
do
  local owner = FibersScope.new():label('backend-contract-owner')
  local ok, err = pcall(function()
    require('fibers.io.handle').new({
      label = 'missing-close',
      key = 'missing-close-key',
      read = function() return nil, 'would_block' end,
    })
  end)
  assert_eq(ok, false)
  assert_truthy(tostring(err):find('requires close', 1, true))

  ok, err = pcall(function()
    Stream.open_op(
      require('fibers.io.handle').new({
        label = 'missing-read',
        key = 'missing-read-key',
        close = function() return true end,
      }),
      { scope = owner, read = true, write = false }
    )
  end)
  assert_eq(ok, false)
  assert_truthy(tostring(err):find('requires read', 1, true))
end

-- A backend readiness_key method may return distinct direction keys.
do
  local rt = FibersRuntime.new()
  local owner = FibersScope.new():label('direction-key-owner')
  local backend = require('fibers.io.handle').new({
    label = 'direction-key-backend',
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
      scope = owner,
      label = 'direction-key-stream',
      read = true,
      write = true,
    }))
  end):label('direction-key-open')
  assert_status(rt:run(), 'found')
  assert_eq(stream._read_registration.key, 'direction-read-key')
  assert_eq(stream._write_registration.key, 'direction-write-key')
  rt:spawn_raw(function()
    rt:perform(stream:request_close_op('done')); rt:perform(stream:closed_op())
    rt:perform(stream:closed_op())
  end):label('direction-key-close')
  drive_until(rt, function()
    return backend.closed == true or rt.host_reactor:_registration_count() == 0
  end)
end

local function run_read_contract_case(name, read_result, expected_bytes, expected_err)
  local rt = FibersRuntime.new()
  local owner = FibersScope.new():label(name .. '-owner')
  local backend = FakeHandle.new({
    label = name .. '-backend',
    readiness = 'manual',
    initial_readable = true,
  })
  function backend:read(_max)
    return read_result()
  end
  local bytes, err
  rt:spawn_raw(function()
    local stream = rt:perform(Stream.open_op(backend, {
      scope = owner,
      label = name .. '-stream',
      read = true,
      write = false,
      read_chunk_size = 16,
    }))
    bytes, err = rt:perform(stream:read_some_op(16))
  end):label(name)
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

-- Host Stream construction requires explicit read and write capabilities.
do
  local backend = FakeHandle.new({ label = 'explicit-stream-options' })
  local owner = FibersScope.new():label('explicit-stream-options-owner')
  local ok, err = pcall(function()
    Stream.open_op(backend, { scope = owner, label = 'missing-directions' })
  end)
  assert_eq(ok, false)
  assert_truthy(tostring(err):find('explicit boolean', 1, true))
end

print('tests/embedding/test_stream_reactor.lua: ok')

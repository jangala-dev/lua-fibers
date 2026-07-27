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
local WaitSet = require('fibers.host.wait_set')
local Inspect = require('tests.support.flow_inspect')

local fibers = require('fibers')
local FakeHandle = require('tests.support.fake_handle')
local FibersOp = require('fibers.op')
local FibersRuntime = require('fibers.runtime')
local FibersScope = require('fibers.scope')
local FibersStream = require('fibers.stream')
local FibersHost = require('fibers.host')
local Op = FibersOp
local Runtime = FibersRuntime
local Host = FibersHost
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

local function drive_until(rt, pred, label, bounded)
  for _ = 1, 500 do
    if pred() then
      return true
    end
    local st = bounded and rt:step({ max_work = 1 }) or rt:run()
    if pred() then
      return true
    end
    if st.tag == 'idle' or st.tag == 'quiescent' then
      break
    end
  end
  fail(label or 'runtime did not reach expected state')
end

-- Runtime-bound readiness feeds invalidate bounded search and deliver stable key/mode values.
do
  local rt = Runtime.new()
  local src, feed = rt:readiness('handle-1', 'readiness-bounded')
  local ok, key, mode
  rt:spawn_raw(function()
    ok, key, mode = rt:perform(src:readable_op())
  end, 'readiness-waiter')
  local st
  for _ = 1, 8 do
    st = rt:step({ max_work = 1 })
  end
  local waits = (st and st.waits or {})
  local rw = WaitSet.readiness_waits(waits)
  assert_eq(#rw, 1, 'one readiness wait expected')
  assert_eq(rw[1].readiness_key, 'handle-1')
  assert_eq(rw[1].mode, 'read')
  feed:readable()
  drive_until(rt, function()
    return ok == true
  end, 'bounded readiness should resume', true)
  assert_eq(key, 'handle-1')
  assert_eq(mode, 'read')
end

-- Read and write readiness modes are independent.
do
  local rt = Runtime.new()
  local src, feed = rt:readiness('handle-2', 'readiness-modes')
  local read_seen, write_seen
  rt:spawn_raw(function()
    read_seen = rt:perform(src:readable_op())
  end, 'read-waiter')
  rt:spawn_raw(function()
    write_seen = rt:perform(src:writable_op())
  end, 'write-waiter')
  assert_status(rt:run(), 'pending')
  feed:writable()
  drive_until(rt, function()
    return write_seen == true
  end, 'write readiness should resume')
  assert_eq(write_seen, true)
  assert_nil(read_seen, 'read waiter should remain pending after write readiness')
  feed:readable()
  drive_until(rt, function()
    return read_seen == true
  end, 'read readiness should resume')
end

-- Clearing readiness removes the latched readiness fact.
do
  local rt = Runtime.new()
  local src, feed = rt:readiness('handle-3', 'readiness-clear')
  feed:readable()
  feed:clear('read')
  local seen
  rt:spawn_raw(function()
    seen = rt:perform(src:readable_op())
  end, 'clear-waiter')
  local st = rt:run()
  assert_status(st, 'pending')
  assert_nil(seen)
end

-- Readiness carries no error or close payload. Backend read/write remains authoritative.
do
  local rt = Runtime.new()
  local owner = FibersScope.new('readiness-authority-owner')
  local backend = FakeHandle.new({
    name = 'readiness-authority-backend',
    readiness = 'manual',
    initial_writable = false,
  })
  local stream, read_val, read_err, n, write_err
  rt:spawn_raw(function()
    stream = rt:perform(
      Stream.open_op(
        backend,
        { scope = owner, read = true, write = true, name = 'readiness-authority-stream' }
      )
    )
    read_val, read_err = rt:perform(stream:reader():read_some_op(1))
    rt:perform(stream:writer():write_op('x'))
    n, write_err = rt:perform(stream:writer():flush_op())
  end, 'authority-root')
  assert_status(rt:run(), 'found')
  backend:feed_read_error('read_reset')
  backend:mark_readable()
  drive_until(rt, function()
    return read_err == 'read_reset'
  end, 'read error should come from backend read')
  backend:fail_writes('write_reset')
  backend:mark_writable()
  drive_until(rt, function()
    return write_err == 'write_reset'
  end, 'write error should come from backend write')
  assert_nil(read_val)
  assert_nil(n)
end

-- Readiness is level-like: if left set, more than one waiter can observe it in separate commits.
do
  local rt = Runtime.new()
  local src, feed = rt:readiness('handle-5', 'readiness-level')
  local a, b
  feed:readable()
  rt:spawn_raw(function()
    a = rt:perform(src:readable_op())
  end, 'level-a')
  rt:spawn_raw(function()
    b = rt:perform(src:readable_op())
  end, 'level-b')
  drive_until(rt, function()
    return a == true and b == true
  end, 'level readiness should be reusable while set')
end

-- Stale read readiness is safe: backend read may still return would_block and
-- no stream bytes appear.
do
  local rt = Runtime.new()
  local owner = FibersScope.new('stale-readiness-owner')
  local backend =
    FakeHandle.new({ name = 'stale-readiness-backend', readiness = 'manual', initial_writable = false })
  local stream, got, err, snap
  rt:spawn_raw(function()
    stream = rt:perform(
      Stream.open_op(backend, { scope = owner, read = true, write = true, name = 'stale-readiness-stream' })
    )
    got, err = rt:perform(stream:reader():read_some_op(1))
  end, 'root')
  assert_status(rt:run(), 'found')
  backend:mark_readable()
  for _ = 1, 20 do
    rt:run()
    if got then
      break
    end
  end
  assert_nil(got, 'stale readable hint should not append bytes')
  assert_nil(err, 'stale readable hint should not commit an error')
  assert_eq(Inspect.reserved(stream:reader().flow), 0, 'would_block must release producer-side capacity')
  backend:feed_read('x')
  backend:mark_readable()
  drive_until(rt, function()
    return got == 'x'
  end, 'later real input should be delivered')
end

-- Write readiness admits a reactor write reaction.
do
  local rt = Runtime.new()
  local owner = FibersScope.new('readiness-write-owner')
  local backend = FakeHandle.new({
    name = 'readiness-write-backend',
    readiness = 'manual',
    initial_writable = false,
    write_blocked = true,
  })
  local stream, flushed
  rt:spawn_raw(function()
    stream = rt:perform(
      Stream.open_op(backend, { scope = owner, read = true, write = true, name = 'readiness-write-stream' })
    )
    rt:perform(stream:writer():write_op('abc'))
    flushed = rt:perform(stream:writer():flush_op())
  end, 'root')
  for _ = 1, 20 do
    rt:run()
    if stream and Inspect.data(stream:writer().flow) == 'abc' then
      break
    end
  end
  assert_truthy(stream, 'stream should open')
  assert_eq(
    Inspect.first_lease_bytes(stream:writer().flow),
    nil,
    'reactor should wait for writability before leasing bytes'
  )
  assert_eq(Inspect.data(stream:writer().flow), 'abc')
  assert_eq(backend:written(), '')
  backend:unblock_writes()
  drive_until(rt, function()
    return flushed == true
  end, 'write readiness should flush leased bytes')
  assert_eq(backend:written(), 'abc')
end

-- Bounded stepping also resumes a readiness-backed write reaction after readiness arrival.
do
  local rt = Runtime.new()
  local owner = FibersScope.new('bounded-ready-reactor-owner')
  local backend = FakeHandle.new({
    name = 'bounded-ready-reactor-backend',
    readiness = 'manual',
    initial_writable = false,
    write_blocked = true,
  })
  local stream, flushed
  rt:spawn_raw(function()
    stream = rt:perform(
      Stream.open_op(
        backend,
        { scope = owner, read = true, write = true, name = 'bounded-ready-reactor-stream' }
      )
    )
    rt:perform(stream:writer():write_op('xy'))
    flushed = rt:perform(stream:writer():flush_op())
  end, 'root')
  for _ = 1, 80 do
    rt:step({ max_work = 1 })
    if stream and Inspect.data(stream:writer().flow) == 'xy' then
      break
    end
  end
  assert_truthy(stream, 'bounded stream should open')
  assert_eq(
    Inspect.first_lease_bytes(stream:writer().flow),
    nil,
    'bounded reactor should not lease before writability'
  )
  backend:unblock_writes()
  drive_until(rt, function()
    return flushed == true
  end, 'bounded readiness should flush')
  assert_eq(backend:written(), 'xy')
end

-- Repeated bounded readiness should not reuse stale continuation frames across
-- cursor suspension, source arrival and resume.  This covers the case where a
-- single visible branch must still be treated as a speculative descent: if it
-- later yields or fails, the attempt state must not retain a half-consumed
-- continuation stack.
do
  for i = 1, 24 do
    local rt = Runtime.new()
    local src, feed = rt:readiness('handle-stress-' .. tostring(i), 'readiness-bounded-stress')
    local ok, key, mode
    rt:spawn_raw(function()
      ok, key, mode = rt:perform(src:readable_op())
    end, 'stress-readiness-waiter')
    for _ = 1, 8 do
      rt:step({ max_work = 1 })
    end
    feed:readable()
    drive_until(rt, function()
      return ok == true
    end, 'bounded readiness stress should resume', true)
    assert_eq(key, 'handle-stress-' .. tostring(i))
    assert_eq(mode, 'read')
  end
end

print('tests/test_readiness.lua: ok')

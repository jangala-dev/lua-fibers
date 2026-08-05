package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')
local External = require('fibers.embed.external')
local Inspect = require('tests.support.flow_inspect')

local fibers = require('fibers')
local FakeHandle = require('tests.support.fake_handle')
local FibersRuntime = require('fibers.runtime')
local FibersScope = require('fibers.scope')
local FibersStream = require('fibers.io.stream')
local ManualHost = require('fibers.embed.manual')
local Runtime = FibersRuntime
local Scope = FibersScope
local Stream = FibersStream
local Handle = require('fibers.io.handle')

local function fail(msg)
  error(msg, 2)
end
local function assert_eq(a, b, msg)
  if a ~= b then
    fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a))
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

local function run(rt, host, iters)
  return External.drive(rt, { host = host, max_iterations = iters or 80 })
end

local function drive_until(rt, host, pred, label, iters)
  for _ = 1, (iters or 20) do
    if pred() then
      return true
    end
    run(rt, host, 80)
    if pred() then
      return true
    end
  end
  fail(label or 'runtime did not reach expected state')
end

-- Readiness marked before runtime attachment survives bind_runtime.  Native
-- providers may discover a level-ready descriptor while constructing it, before
-- Stream.open_op attaches the handle to the runtime-owned reactor.
do
  local host = ManualHost.new({ auto_advance_time = false })
  local rt = Runtime.new({ host = host })
  local owner = Scope.new():label('prebind-ready-owner')
  local written, flushed = '', false
  local handle = Handle.new({
    host = host,
    key = 'prebind-ready-handle',
    name = 'prebind-ready-handle',
    write = function(_, bytes)
      written = written .. bytes
      return #bytes
    end,
    close = function()
      return true
    end,
  })
  handle:mark_writable()
  rt:spawn_raw(function()
    local stream = rt:perform(
      Stream.open_op(handle, { scope = owner, name = 'prebind-ready-stream', read = false, write = true })
    )
    rt:perform(stream:writer():write_op('ready'))
    flushed = rt:perform(stream:writer():flush_op())
  end):label('prebind-ready-writer')
  drive_until(rt, host, function()
    return flushed == true
  end, 'pre-bind writable hint should drive the first reactor write')
  assert_eq(written, 'ready')
end

-- A fake HostHandle opens through the handle backend and Stream.open_op and drives the read reaction.
do
  local host = ManualHost.new({ auto_advance_time = false })
  local rt = Runtime.new({ host = host })
  local owner = Scope.new():label('handle-read-owner')
  local handle = FakeHandle.new({ host = host, key = 'fake-read-handle' })
  local stream, got

  rt:spawn_raw(function()
    stream = rt:perform(
      Stream.open_op(handle, { scope = owner, name = 'handle-read-stream', read = true, write = false })
    )
    got = rt:perform(stream:reader():read_exactly_op(4))
  end):label('handle-reader')

  local st = run(rt, host, 80)
  assert_status(st, 'pending')
  assert_truthy(stream, 'stream should open before waiting for input')
  handle:feed_read('ping')
  drive_until(rt, host, function()
    return got == 'ping'
  end, 'handle read should deliver bytes')
  assert_eq(got, 'ping')
end

-- A fake HostHandle drives the write reaction; blocking and later writability are
-- host facts rather than stream facts.
do
  local host = ManualHost.new({ auto_advance_time = false })
  local rt = Runtime.new({ host = host })
  local owner = Scope.new():label('handle-write-owner')
  local handle = FakeHandle.new({ host = host, key = 'fake-write-handle', write_blocked = true })
  local stream, flushed

  rt:spawn_raw(function()
    stream = rt:perform(
      Stream.open_op(handle, { scope = owner, name = 'handle-write-stream', read = false, write = true })
    )
    rt:perform(stream:writer():write_op('hello'))
    flushed = rt:perform(stream:writer():flush_op())
  end):label('handle-writer')

  local st = run(rt, host, 80)
  assert_status(st, 'pending')
  assert_truthy(stream, 'stream should open before waiting for writability')
  assert_eq(
    Inspect.first_lease_bytes(stream:writer().flow),
    nil,
    'reactor should not lease bytes before a writable hint'
  )
  assert_eq(Inspect.data(stream:writer().flow), 'hello')
  assert_eq(handle:written(), '')
  handle:unblock_writes()
  drive_until(rt, host, function()
    return flushed == true
  end, 'handle write should flush')
  assert_eq(handle:written(), 'hello')
end

-- Native descriptor implementations are private to their selected host family.
print('tests/test_host_handle.lua: ok')

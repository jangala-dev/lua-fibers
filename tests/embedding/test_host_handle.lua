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
local FibersRunner = require('fibers.runner')
local FibersHost = require('fibers.host')
local Host = FibersHost
local Runtime = FibersRuntime
local Runner = FibersRunner
local Region = FibersRegion
local Stream = FibersStream
local Handle = require('fibers.host.handle')
local HandleBackend = require('fibers.stream.backend.handle')

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
  return Runner.run(rt, { host = host, max_iterations = iters or 80 })
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
  local host = Host.manual({ auto_advance_time = false })
  local rt = Runtime.new({ host = host })
  local region = Region.new('prebind-ready-region')
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
      Stream.open_op(
        HandleBackend.new(handle, { name = 'prebind-ready-stream' }),
        { owner = region, name = 'prebind-ready-stream', read = false, write = true }
      )
    )
    rt:perform(stream:writer():write_op('ready'))
    flushed = rt:perform(stream:writer():flush_op())
  end, 'prebind-ready-writer')
  drive_until(rt, host, function()
    return flushed == true
  end, 'pre-bind writable hint should drive the first reactor write')
  assert_eq(written, 'ready')
end

-- A fake HostHandle opens through the handle backend and Stream.open_op and drives the read reaction.
do
  local host = Host.manual({ auto_advance_time = false })
  local rt = Runtime.new({ host = host })
  local region = Region.new('handle-read-region')
  local handle = Handle.fake({ host = host, key = 'fake-read-handle' })
  local stream, got

  rt:spawn_raw(function()
    stream = rt:perform(
      Stream.open_op(
        HandleBackend.new(handle, { name = 'handle-read-stream' }),
        { owner = region, name = 'handle-read-stream', read = true, write = false }
      )
    )
    got = rt:perform(stream:reader():read_exactly_op(4))
  end, 'handle-reader')

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
  local host = Host.manual({ auto_advance_time = false })
  local rt = Runtime.new({ host = host })
  local region = Region.new('handle-write-region')
  local handle = Handle.fake({ host = host, key = 'fake-write-handle', write_blocked = true })
  local stream, flushed

  rt:spawn_raw(function()
    stream = rt:perform(
      Stream.open_op(
        HandleBackend.new(handle, { name = 'handle-write-stream' }),
        { owner = region, name = 'handle-write-stream', read = false, write = true }
      )
    )
    rt:perform(stream:writer():write_op('hello'))
    flushed = rt:perform(stream:writer():flush_op())
  end, 'handle-writer')

  local st = run(rt, host, 80)
  assert_status(st, 'pending')
  assert_truthy(stream, 'stream should open before waiting for writability')
  assert_eq(
    Inspect.first_lease_bytes(stream:writer().flow.reservoir),
    nil,
    'reactor should not lease bytes before a writable hint'
  )
  assert_eq(Inspect.data(stream:writer().flow.reservoir), 'hello')
  assert_eq(handle:written(), '')
  handle:unblock_writes()
  drive_until(rt, host, function()
    return flushed == true
  end, 'handle write should flush')
  assert_eq(handle:written(), 'hello')
end

-- The fd module is a registry/selector; concrete fd options are exposed
-- through selected host families or explicit fd backend selection.
do
  local ok, Fd = pcall(require, 'fibers.host.fd')
  assert_truthy(ok, 'fibers.host.fd should be require-able')
  assert_truthy(type(Fd.select) == 'function', 'fd registry should expose select')
  assert_truthy(type(Fd.available) == 'function', 'fd registry should expose available')
  local ok_sel, backend = pcall(function()
    return Fd.select('luajit')
  end)
  assert_truthy(ok_sel and backend, 'fd registry should select luajit backend')
end

print('tests/test_host_handle.lua: ok')

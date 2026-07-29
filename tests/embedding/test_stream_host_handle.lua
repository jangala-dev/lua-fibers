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
local FibersRuntime = require('fibers.runtime')
local FibersReadiness = require('fibers.host.readiness')
local FibersScope = require('fibers.scope')
local FibersStream = require('fibers.stream')
local FibersHost = require('fibers.host')
local Host = FibersHost
local Runtime = FibersRuntime
local Scope = FibersScope
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
local function assert_truthy(v, msg)
  if not v then
    fail(msg or 'expected truthy')
  end
end
local function assert_nil(v, msg)
  if v ~= nil then
    fail((msg or 'expected nil') .. ': got ' .. tostring(v))
  end
end
local function assert_status(st, tag, msg)
  if not st or st.tag ~= tag then
    fail((msg or 'status mismatch') .. ': expected ' .. tostring(tag) .. ', got ' .. tostring(st and st.tag))
  end
end

local function run(rt, host, iters)
  return rt:drive({ host = host, max_iterations = iters or 80 })
end

local function drive_until(rt, host, pred, label, iters)
  for _ = 1, (iters or 20) do
    if pred() then
      return true
    end
    run(rt, host, 40)
    if pred() then
      return true
    end
  end
  fail(label or 'runtime did not reach expected state')
end

local function make_socket(host, key)
  local h = {
    key = key,
    input = {},
    output = {},
    eof = false,
    read_error = nil,
    write_error = nil,
    read_blocked = false,
    write_blocked = false,
    write_chunk_size = nil,
    shutdown_read_reason = nil,
    shutdown_write_reason = nil,
  }

  function h:feed(bytes)
    if bytes and bytes ~= '' then
      self.input[#self.input + 1] = bytes
    end
    host:readable(self.key)
  end

  function h:feed_eof()
    self.eof = true
    host:readable(self.key)
  end

  function h:fail_read(err)
    self.read_error = err or 'read_error'
    host:readable(self.key)
  end

  function h:read(max)
    max = max or 4096
    if self.read_blocked then
      host:clear_readiness(self.key, 'read')
      return nil, 'would_block'
    end
    if #self.input > 0 then
      local first = self.input[1]
      local n = math.min(#first, max)
      local out = string.sub(first, 1, n)
      local rest = string.sub(first, n + 1)
      if rest == '' then
        table.remove(self.input, 1)
      else
        self.input[1] = rest
      end
      if #self.input == 0 and not self.eof and not self.read_error then
        host:clear_readiness(self.key, 'read')
      end
      return out
    end
    if self.read_error then
      local err = self.read_error
      self.read_error = nil
      host:clear_readiness(self.key, 'read')
      return nil, err
    end
    if self.eof then
      self.eof = false
      host:clear_readiness(self.key, 'read')
      return nil, 'eof'
    end
    host:clear_readiness(self.key, 'read')
    return nil, 'would_block'
  end

  function h:write(bytes)
    if self.write_error then
      return nil, self.write_error
    end
    if self.write_blocked then
      host:clear_readiness(self.key, 'write')
      return nil, 'would_block'
    end
    local n = math.min(#bytes, self.write_chunk_size or #bytes)
    if n <= 0 then
      return 0
    end
    self.output[#self.output + 1] = string.sub(bytes, 1, n)
    host:writable(self.key)
    return n
  end

  function h:written()
    return table.concat(self.output)
  end

  function h:shutdown_read(reason)
    self.shutdown_read_reason = reason or true
    return true
  end

  function h:shutdown_write(reason)
    self.shutdown_write_reason = reason or true
    return true
  end

  function h:close(reason)
    self:shutdown_read(reason)
    self:shutdown_write(reason)
    return true
  end

  return h
end

local function wrap_handle(host, h)
  return HostHandle.new({
    name = h.key .. '-handle',
    key = h.key,
    host = host,
    read = function(_handle, max)
      return h:read(max)
    end,
    write = function(_handle, bytes)
      return h:write(bytes)
    end,
    shutdown_read = function(_handle, reason)
      return h:shutdown_read(reason)
    end,
    shutdown_write = function(_handle, reason)
      return h:shutdown_write(reason)
    end,
    close = function(_handle, reason)
      return h:close(reason)
    end,
  })
end

-- Manual host delivers readiness waits through the same runtime-bound source path
-- as OS hosts, and preserves key/mode in wait summaries.
do
  local host = Host.manual({ auto_advance_time = false })
  local rt = Runtime.new({ host = host })
  local src = FibersReadiness.new('manual-key', 'read', 'manual-key-readiness')
  local seen, key, mode
  rt:spawn_raw(function()
    seen, key, mode = rt:perform(src:readable_op())
  end, 'manual-readiness')
  local st = run(rt, host, 5)
  assert_status(st, 'pending')
  local waits = (st.waits or {})
  local rw = WaitSet.readiness_waits(waits)
  assert_eq(#rw, 1)
  assert_eq(rw[1].readiness_key, 'manual-key')
  assert_eq(rw[1].mode, 'read')
  host:readable('manual-key')
  st = run(rt, host, 20)
  assert_status(st, 'found')
  assert_eq(seen, true)
  assert_eq(key, 'manual-key')
  assert_eq(mode, 'read')
end

-- A socket-shaped backend uses host readiness to drive the existing read reaction.
do
  local host = Host.manual({ auto_advance_time = false })
  local rt = Runtime.new({ host = host })
  local owner = Scope.new('socket-read-owner')
  local handle = make_socket(host, 'socket-read')
  local stream_handle = wrap_handle(host, handle)
  local stream, got

  rt:spawn_raw(function()
    stream = rt:perform(
      Stream.open_op(stream_handle, { scope = owner, read = true, write = true, name = 'socket-read-stream' })
    )
    got = rt:perform(stream:reader():read_exactly_op(3))
  end, 'socket-reader')

  local st = run(rt, host, 80)
  assert_status(st, 'pending')
  assert_truthy(stream, 'stream should have opened before waiting for input')
  handle:feed('abc')
  drive_until(rt, host, function()
    return got == 'abc'
  end, 'socket read should deliver bytes')
  assert_eq(got, 'abc')
end

-- Write readiness drives the write reaction, and host writes remain authoritative.
do
  local host = Host.manual({ auto_advance_time = false })
  local rt = Runtime.new({ host = host })
  local owner = Scope.new('socket-write-owner')
  local handle = make_socket(host, 'socket-write')
  handle.write_blocked = true
  local stream_handle = wrap_handle(host, handle)
  local stream, flushed

  rt:spawn_raw(function()
    stream = rt:perform(
      Stream.open_op(
        stream_handle,
        { scope = owner, read = true, write = true, name = 'socket-write-stream' }
      )
    )
    rt:perform(stream:writer():write_op('hello'))
    flushed = rt:perform(stream:writer():flush_op())
  end, 'socket-writer')

  local st = run(rt, host, 80)
  assert_status(st, 'pending')
  assert_truthy(stream, 'stream should open')
  assert_eq(
    Inspect.first_lease_bytes(stream:writer().flow),
    nil,
    'reactor should not lease before host writability'
  )
  assert_eq(Inspect.data(stream:writer().flow), 'hello')
  assert_eq(handle:written(), '')
  handle.write_blocked = false
  host:writable(handle.key)
  drive_until(rt, host, function()
    return flushed == true
  end, 'socket write should flush')
  assert_eq(flushed, true)
  assert_eq(handle:written(), 'hello')
end

-- Partial host writes preserve the byte stream through committed in-flight leases.
do
  local host = Host.manual({ auto_advance_time = false })
  local rt = Runtime.new({ host = host })
  local owner = Scope.new('socket-partial-owner')
  local handle = make_socket(host, 'socket-partial')
  handle.write_chunk_size = 2
  host:writable(handle.key)
  local stream_handle = wrap_handle(host, handle)
  local stream, flushed

  rt:spawn_raw(function()
    stream = rt:perform(
      Stream.open_op(
        stream_handle,
        { scope = owner, read = true, write = true, name = 'socket-partial-stream' }
      )
    )
    rt:perform(stream:writer():write_op('abcdef'))
    flushed = rt:perform(stream:writer():flush_op())
  end, 'socket-partial-writer')

  drive_until(rt, host, function()
    return flushed == true
  end, 'partial socket write should flush', 40)
  assert_eq(flushed, true)
  assert_eq(handle:written(), 'abcdef')
end

-- EOF and read errors arrive through handle read, not readiness payloads.
do
  local host = Host.manual({ auto_advance_time = false })
  local rt = Runtime.new({ host = host })
  local owner = Scope.new('socket-eof-owner')
  local handle = make_socket(host, 'socket-eof')
  local stream_handle = wrap_handle(host, handle)
  local stream, first, second, err

  rt:spawn_raw(function()
    stream = rt:perform(
      Stream.open_op(stream_handle, { scope = owner, read = true, write = true, name = 'socket-eof-stream' })
    )
    first = rt:perform(stream:reader():read_some_op(8))
    second, err = rt:perform(stream:reader():read_some_op(8))
  end, 'socket-eof-reader')

  assert_status(run(rt, host, 80), 'pending')
  handle:feed('xy')
  handle:feed_eof()
  drive_until(rt, host, function()
    return err == 'eof'
  end, 'socket EOF should be delivered', 40)
  assert_eq(first, 'xy')
  assert_nil(second)
  assert_eq(err, 'eof')
end

print('tests/test_stream_host_handle.lua: ok')

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

local Runtime = require('fibers.runtime')
local Poller = require('fibers.host.poller')
local Stream = require('fibers.stream')
local Region = require('fibers.lifetime.region')
local UnsafeExternalMutation = require('fibers.internal.unsafe_external_mutation')

local function fail(msg)
  error(msg, 2)
end
local function assert_eq(a, b, msg)
  if a ~= b then
    fail((msg or 'assert_eq') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a))
  end
end
local function assert_truthy(v, msg)
  if not v then
    fail(msg or 'expected truthy')
  end
end

-- Registration churn is compacted rather than retaining an unbounded history.
do
  local rt = Runtime.new()
  local poller = Poller.new(rt, { change_limit = 8 })
  poller:register({ id = 'r', generation = 1, key = 'key', mode = 'read' })
  for _ = 1, 100 do
    poller:arm('r', 1)
    poller:disarm('r', 1)
  end
  assert_truthy(#poller.changes <= 8, 'poller change history should remain bounded')
  poller:retire('r', 1)
  assert_eq(poller:registration_count(), 0)
end

-- Stale readiness for an earlier registration generation is ignored by the reactor.
do
  local rt = Runtime.new()
  local region = Region.new('poller-generation-region')
  local backend = require('fibers.stream.backend.fake').new({
    name = 'poller-generation-backend',
    readiness = 'manual',
    initial_readable = false,
  })
  local reads = 0
  local original_read = backend.read
  function backend:read(max)
    reads = reads + 1
    return original_read(self, max)
  end
  local stream
  rt:spawn_raw(function()
    stream = rt:perform(Stream.open_op(backend, {
      owner = region,
      name = 'poller-generation-stream',
      read = true,
      write = false,
    }))
  end, 'root')
  assert_eq(rt:run().tag, 'found')
  local entry = stream.read_registration
  UnsafeExternalMutation.deliver(
    rt.host_poller.ready,
    entry._fibers_id,
    entry.generation - 1,
    'read',
    entry.key
  )
  rt:run()
  assert_eq(reads, 0, 'stale readiness must not invoke the backend')
  local audit = rt:io_audit_snapshot()
  assert_eq(audit.stats.stale_ready, 1, 'stale readiness should be observable')
  rt:spawn_raw(function()
    rt:perform(stream:abort_op('test complete'))
  end, 'close')
  rt:run()
  rt:assert_io_quiescent('stale readiness test')
end

-- The poller hot queue is a persistent FIFO: large bursts retain order without
-- the array-copying EventQueue path.
do
  local PollerQueue = require('fibers.host.poller_queue')
  local UnsafeExternalMutation = require('fibers.internal.unsafe_external_mutation')
  local q = PollerQueue.new('poller-burst')
  local rt = Runtime.new()
  local consumed = 0
  for i = 1, 5000 do
    UnsafeExternalMutation.deliver(q, i)
  end
  assert_eq(q:length(), 5000)
  rt:spawn_raw(function()
    for i = 1, 5000 do
      local value = rt:perform(q:next_op())
      assert_eq(value, i, 'poller queue must preserve FIFO order')
      consumed = i
    end
  end, 'poller-burst-consumer')
  assert_eq(rt:run().tag, 'found')
  assert_eq(consumed, 5000)
  assert_eq(q:length(), 0)
end

print('tests/embedding/test_host_poller.lua: ok')

package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

local IOAudit = require('fibers.diagnostics.io')
local FakeHandle = require('tests.support.fake_handle')
local Runtime = require('fibers.runtime')
local Stream = require('fibers.io.stream')
local Scope = require('fibers.scope')
local UnsafeExternalMutation = require('fibers.embed.unsafe_external_mutation')
require('fibers.diagnostics.io').install(require('fibers.diagnostics.io_observer'))

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

-- Stale readiness for an earlier registration generation is ignored by the reactor.
do
  local rt = Runtime.new()
  local owner = Scope.new('poller-generation-owner')
  local backend = FakeHandle.new({
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
      scope = owner,
      name = 'poller-generation-stream',
      read = true,
      write = false,
    }))
  end, 'root')
  assert_eq(rt:run().tag, 'found')
  local entry = stream.read_registration
  UnsafeExternalMutation.deliver(
    rt.host_reactor.ready,
    entry._fibers_id,
    entry.generation - 1,
    'read',
    entry.key
  )
  rt:run()
  assert_eq(reads, 0, 'stale readiness must not invoke the backend')
  local audit = IOAudit.report(rt)
  assert_eq(audit.stats.stale_ready, 1, 'stale readiness should be observable')
  rt:spawn_raw(function()
    rt:perform(stream:abort_op('test complete'))
  end, 'close')
  rt:run()
  IOAudit.assert_clean(rt, { label = 'stale readiness test' })
end

-- The shared external event queue is the poller hot FIFO.
do
  local EventQueue = require('fibers.resource.event_queue')
  local UnsafeExternalMutation = require('fibers.embed.unsafe_external_mutation')
  local q = EventQueue.new('poller-burst')
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

  -- A drain must include an existing front item and later arrivals held in the
  -- persistent back list. This is the shape used by scope lifetime events.
  UnsafeExternalMutation.deliver(q, 'first')
  UnsafeExternalMutation.deliver(q, 'second')
  UnsafeExternalMutation.deliver(q, 'third')
  local drained
  rt:spawn_raw(function()
    drained = rt:perform(q:_drain_op())
  end, 'poller-mixed-drain')
  assert_eq(rt:run().tag, 'found')
  assert_eq(#drained, 3)
  assert_eq(drained[1][1], 'first')
  assert_eq(drained[2][1], 'second')
  assert_eq(drained[3][1], 'third')
  assert_eq(q:length(), 0)
end

-- Stateless hosts share one plan for readiness resources and indexed poller registrations.
do
  local WaitSet = require('fibers.embed.wait_set')
  local key = {}
  local readiness_feed, poller_feed = {}, {}
  local registration = { id = 'shared', generation = 1, key = key, mode = 'write' }
  local poller = {
    _host_active = function()
      return { registration }
    end,
    _host_delivered = function(_, current)
      return current == registration
    end,
  }
  local plan = WaitSet.build({
    {
      kind = 'external',
      external_kind = 'readiness',
      resource = {},
      feed = readiness_feed,
      readiness_key = key,
      mode = 'read',
    },
    {
      kind = 'external',
      external_kind = 'poller',
      poller = poller,
      feed = poller_feed,
    },
  })
  assert_eq(#plan.records, 1)
  assert_truthy(plan.records[1].read and plan.records[1].write)

  local delivered = {}
  function readiness_feed:set(...)
    delivered[#delivered + 1] = { feed = self, values = { ... } }
  end
  function poller_feed:set(...)
    delivered[#delivered + 1] = { feed = self, values = { ... } }
  end
  assert_truthy(WaitSet.deliver(nil, plan.records[1], true, true))
  assert_eq(#delivered, 2)
  assert_eq(delivered[1].feed, readiness_feed)
  assert_eq(delivered[2].feed, poller_feed)
end

-- Nixio readiness delivery must not depend on the returned fd retaining the
-- identity of the object supplied to poll(). Nixio documents in-place mutation,
-- and the host binding tolerates both an omitted second return and a returned
-- table whose fd field is the integer descriptor rather than the original object.
do
  local module_names = {
    'nixio',
    'fibers.io.nixio',
  }
  local saved_loaded, saved_preload = {}, {}
  for i = 1, #module_names do
    local name = module_names[i]
    saved_loaded[name] = package.loaded[name]
    saved_preload[name] = package.preload[name]
    package.loaded[name] = nil
  end

  local polled_mode = 'in-place'
  local descriptor_read, descriptor_write = {}, {}
  function descriptor_read:fileno()
    return 77
  end
  function descriptor_write:fileno()
    return 88
  end

  package.preload.nixio = function()
    return {
      gettime = function()
        return 0
      end,
      nanosleep = function()
        return true
      end,
      pipe = function()
        return {}, {}
      end,
      poll_flags = function(first, second)
        if type(first) == 'number' then
          return { ['in'] = first == 1 or first == 3, out = first == 2 or first == 3 }
        end
        if first == 'in' and second == 'out' or first == 'out' and second == 'in' then
          return 3
        end
        return first == 'out' and 2 or 1
      end,
      poll = function(fds)
        if polled_mode == 'in-place' then
          for i = 1, #fds do
            local fd = fds[i].fd:fileno()
            fds[i].fd = fd
            fds[i].revents = fd == 77 and 1 or 2
          end
          return 2
        end
        -- Deliberately reverse and compress the returned records.  Correct
        -- delivery must use raw descriptor identity, never returned position.
        return 2, { { fd = 88, revents = 2 }, { fd = 77, revents = 1 } }
      end,
    }
  end

  local ok, err = pcall(function()
    local NixioHost = require('fibers.io.nixio')
    local host = NixioHost.new()
    local delivered = {}
    local rt = {
      now = function()
        return 0
      end,
    }
    local read_feed, write_feed = {}, {}
    function read_feed:set(mode, value)
      delivered[#delivered + 1] = { feed = self, mode = mode, value = value }
    end
    function write_feed:set(mode, value)
      delivered[#delivered + 1] = { feed = self, mode = mode, value = value }
    end
    local waits = {
      {
        kind = 'external',
        external_kind = 'readiness',
        resource = {},
        feed = read_feed,
        readiness_key = { family = 'nixio', poll = descriptor_read, number = 77, generation = 1 },
        mode = 'read',
      },
      {
        kind = 'external',
        external_kind = 'readiness',
        resource = {},
        feed = write_feed,
        readiness_key = { family = 'nixio', poll = descriptor_write, number = 88, generation = 2 },
        mode = 'write',
      },
    }

    local blocked, reason = host:block(rt, waits, {}, {})
    assert_eq(blocked, true)
    assert_eq(reason, 'readiness')
    assert_eq(#delivered, 2)
    local modes = {}
    for i = 1, #delivered do
      modes[delivered[i].feed] = delivered[i].mode
    end
    assert_eq(modes[read_feed], 'read')
    assert_eq(modes[write_feed], 'write')

    polled_mode = 'returned-copy'
    delivered = {}
    blocked, reason = host:block(rt, waits, {}, {})
    assert_eq(blocked, true)
    assert_eq(reason, 'readiness')
    assert_eq(#delivered, 2)
    local modes = {}
    for i = 1, #delivered do
      modes[delivered[i].feed] = delivered[i].mode
    end
    assert_eq(modes[read_feed], 'read')
    assert_eq(modes[write_feed], 'write')
  end)

  for i = 1, #module_names do
    local name = module_names[i]
    package.loaded[name] = saved_loaded[name]
    package.preload[name] = saved_preload[name]
  end
  assert(ok, err)
end

print('tests/embedding/test_host_poller.lua: ok')

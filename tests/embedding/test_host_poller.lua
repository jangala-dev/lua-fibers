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
  local backend = require('fibers.host.handle').fake({
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

-- Stateless hosts share one plan for readiness resources and indexed poller registrations.
do
  local PollPlan = require('fibers.host.poll_plan')
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
  local plan = PollPlan.build({
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
  local rt = {
    deliver = function(_, feed, ...)
      delivered[#delivered + 1] = { feed = feed, values = { ... } }
    end,
  }
  assert_truthy(PollPlan.deliver(rt, plan.records[1], true, true))
  assert_eq(#delivered, 2)
  assert_eq(delivered[1].feed, readiness_feed)
  assert_eq(delivered[2].feed, poller_feed)
end

-- Nixio readiness delivery must not depend on the returned fd retaining the
-- identity of the object supplied to poll(). Nixio documents in-place mutation,
-- and the host adapter tolerates both an omitted second return and a returned
-- table whose fd field is the integer descriptor rather than the original object.
do
  local module_names = {
    'nixio',
    'fibers.host.nixio',
    'fibers.host.fd_nixio',
    'fibers.host.datagram_nixio',
    'fibers.host.socket_nixio',
    'fibers.host.resolver_nixio',
    'fibers.host.process_nixio',
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

  package.preload['fibers.host.fd_nixio'] = function()
    return {
      is_supported = function()
        return true
      end,
    }
  end
  package.preload['fibers.host.datagram_nixio'] = function()
    return {
      is_supported = function()
        return false
      end,
    }
  end
  package.preload['fibers.host.socket_nixio'] = function()
    return {
      is_supported = function()
        return false
      end,
      supports_ipv4 = function()
        return false
      end,
      supports_ipv6 = function()
        return false
      end,
      supports_unix = function()
        return false
      end,
    }
  end
  package.preload['fibers.host.resolver_nixio'] = function()
    return {
      is_supported = function()
        return false
      end,
    }
  end
  package.preload['fibers.host.process_nixio'] = function()
    return {
      is_supported = function()
        return false
      end,
    }
  end

  local ok, err = pcall(function()
    local NixioHost = require('fibers.host.nixio')
    local host = NixioHost.new()
    local delivered = {}
    local rt = {
      now = function()
        return 0
      end,
      deliver = function(_, feed, mode, value)
        delivered[#delivered + 1] = { feed = feed, mode = mode, value = value }
      end,
    }
    local read_feed, write_feed = {}, {}
    local waits = {
      {
        kind = 'external',
        external_kind = 'readiness',
        resource = {},
        feed = read_feed,
        readiness_key = { family = 'nixio', handle = descriptor_read },
        mode = 'read',
      },
      {
        kind = 'external',
        external_kind = 'readiness',
        resource = {},
        feed = write_feed,
        readiness_key = { family = 'nixio', handle = descriptor_write },
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

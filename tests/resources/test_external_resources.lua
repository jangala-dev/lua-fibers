-- External resource semantics tests.
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

local Op = require('fibers.op')
local Runtime = require('fibers.runtime')

local function deliver(rt, resource, ...)
  return rt:external_feed(resource):set(...)
end
local Signal = require('fibers.resource.signal')
local EventQueue = require('fibers.resource.event_queue')
local Clock = require('fibers.resource.clock')
local Readiness = require('fibers.host.readiness')
local Rendezvous = require('fibers.resource.rendezvous')

local function fail(msg)
  error(msg, 2)
end
local function assert_eq(a, b, msg)
  if a ~= b then
    fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a))
  end
end
local function assert_status(st, tag, msg)
  if not st or st.tag ~= tag then
    fail((msg or 'status mismatch') .. ': expected ' .. tag .. ', got ' .. tostring(st and st.tag))
  end
end

-- Not ready now, but fallback is available now: fallback commits.
do
  local ev = Signal.new('unset')
  local rt = Runtime.new()
  local got
  rt:spawn_raw(function()
    got = rt:perform(ev:wait_op():or_else(Op.always('fallback')))
  end, 'fallback-on-not-ready')
  assert_status(rt:run(), 'found')
  assert_eq(got, 'fallback')
end

-- Not ready now, no fallback: runtime reports pending wake interests, not absence.
do
  local ev = Signal.new('pending')
  local rt = Runtime.new()
  local got
  rt:spawn_raw(function()
    got = rt:perform(ev:wait_op())
  end, 'pending-no-fallback')
  local st = rt:run()
  assert_status(st, 'pending')
  assert_eq(got, nil)
  assert(st.waits and #st.waits == 1, 'expected one wake interest')
end

-- Ready now beats fallback.
do
  local ev = Signal.new('ready')
  local rt = Runtime.new()
  deliver(rt, ev, 'payload')
  local got
  rt:spawn_raw(function()
    got = rt:perform(ev:wait_op():or_else(Op.always('fallback')))
  end, 'ready-beats-fallback')
  assert_status(rt:run(), 'found')
  assert_eq(got, 'payload')
end

-- Ready external value still participates in the global rendezvous search.
do
  local ev = Signal.new('ready-with-rendezvous')
  local ch = Rendezvous.new('external-plus-rendezvous')
  local rt = Runtime.new()
  deliver(rt, ev, 'payload')
  local receiver, sender
  rt:spawn_raw(function()
    receiver = rt:perform(ev:wait_op()
      :and_then(function(v)
        return ch:get_op():map(function(x)
          return v .. ':' .. x
        end)
      end)
      :or_else(Op.always('fallback')))
  end, 'receiver')
  rt:spawn_raw(function()
    sender = rt:perform(ch:put_op('rv'))
  end, 'sender')
  assert_status(rt:run(), 'found')
  assert_eq(receiver, 'payload:rv')
  assert_eq(sender, true)
end

-- Clock resources use host time and report a time wait while the deadline is future.
do
  local now = 0
  local clock = Clock.new('source-clock-test')
  local rt = Runtime.new({ host = {
    now = function()
      return now
    end,
  } })
  local ok, observed
  rt:spawn_raw(function()
    ok, observed = rt:perform(clock:at_op(5))
  end, 'clock-waiter')
  local st = rt:run()
  assert_status(st, 'pending')
  assert(st.waits and #st.waits == 1, 'expected one time wait')
  now = 5
  st = rt:step()
  assert_status(st, 'found')
  assert_eq(ok, true)
  assert_eq(observed, 5)
end

-- ExternalFeed delivery is the host/resource boundary for bounded stepping.
do
  local ev = Signal.new('bounded-arrival')
  local rt = Runtime.new()
  local got
  rt:spawn_raw(function()
    got = rt:perform(ev:wait_op())
  end, 'bounded-arrival-waiter')
  for _ = 1, 5 do
    rt:step({ max_work = 1 })
  end
  deliver(rt, ev, 'arrived')
  local st
  for _ = 1, 20 do
    st = rt:step({ max_work = 1 })
    if got then
      break
    end
  end
  assert_eq(got, 'arrived')
  assert(
    st and (st.tag == 'found' or st.tag == 'pending'),
    'expected bounded stepping to resume after arrival'
  )
end

-- Event queues consume occurrences only if the selected transaction commits.
do
  local q = EventQueue.new('events-source')
  local rt = Runtime.new()
  deliver(rt, q, 'a')
  deliver(rt, q, 'b', 'bee')
  local first, second_a, second_b
  rt:spawn_raw(function()
    first = rt:perform(q:next_op())
    second_a, second_b = rt:perform(q:next_op())
  end, 'events-consumer')
  assert_status(rt:run(), 'found')
  assert_eq(first, 'a')
  assert_eq(second_a, 'b')
  assert_eq(second_b, 'bee')
end

-- A losing events branch does not consume the occurrence.
do
  local q = EventQueue.new('events-loser')
  local rt = Runtime.new()
  deliver(rt, q, 'kept')
  local got, remaining
  rt:spawn_raw(function()
    got = rt:perform(Op.choice(
      q:next_op():and_then(function()
        return Op.never()
      end),
      Op.always('winner')
    ))
    remaining = rt:perform(q:next_op())
  end, 'events-loser-consumer')
  assert_status(rt:run(), 'found')
  assert_eq(got, 'winner')
  assert_eq(remaining, 'kept')
end

-- Bounded clock cursors are invalidated by observation once the observed deadline matures.
do
  local now = 0
  local clock = Clock.new('bounded-clock-observation')
  local rt = Runtime.new({ host = {
    now = function()
      return now
    end,
  } })
  local ok, observed
  rt:spawn_raw(function()
    ok, observed = rt:perform(clock:at_op(5))
  end, 'bounded-clock-waiter')
  for _ = 1, 5 do
    rt:step({ max_work = 1 })
  end
  assert_eq(ok, nil, 'sleep should still be pending before deadline')
  now = 5
  local st
  for _ = 1, 30 do
    st = rt:step({ max_work = 1 })
    if ok then
      break
    end
  end
  assert_eq(ok, true, 'bounded clock wait should commit after deadline without explicit invalidation')
  assert_eq(observed, 5)
end

-- Observation also protects external resource observations if a producer
-- bypasses the runtime-wide epoch.
do
  local UnsafeExternalMutation = require('fibers.host.unsafe_external_mutation')
  local ev = Signal.new('bounded-source-observation')
  local rt = Runtime.new()
  local got
  rt:spawn_raw(function()
    got = rt:perform(ev:wait_op())
  end, 'bounded-source-observation-waiter')
  for _ = 1, 5 do
    rt:step({ max_work = 1 })
  end
  UnsafeExternalMutation.deliver(ev, 'direct') -- deliberate internal mutation; no rt epoch bump
  local st
  for _ = 1, 30 do
    st = rt:step({ max_work = 1 })
    if got then
      break
    end
  end
  assert_eq(got, 'direct', 'resource frontier observation should invalidate stale bounded cursor')
end

-- Fallback opened because a deadline was absent-now must be rechecked if the
-- deadline matures before commit.
do
  local now = 0
  local clock = Clock.new('bounded-clock-or-else-observation')
  local rt = Runtime.new({ host = {
    now = function()
      return now
    end,
  } })
  local got
  rt:spawn_raw(function()
    got = rt:perform(clock
      :at_op(5)
      :map(function()
        return 'time'
      end)
      :or_else(Op.always('fallback')))
  end, 'bounded-clock-or-else')
  rt:step({ max_work = 1 }) -- build candidates, observing now < 5 and opening fallback
  now = 5
  local st
  for _ = 1, 30 do
    st = rt:step({ max_work = 1 })
    if got then
      break
    end
  end
  assert_eq(got, 'time', 'matured primary should beat stale fallback proof')
end

-- External feeds are resource-generic capabilities rather than resource-kind checks.
do
  local ExternalFeed = require('fibers.host.external').Feed
  local rt = Runtime.new()
  local resource = {
    _fibers_external_deliver = function(self, value)
      self.value = value
    end,
    _fibers_external_clear = function(self)
      self.value = nil
    end,
  }
  local feed = ExternalFeed.for_resource(rt, resource)
  assert_eq(feed.deliver, nil, 'ExternalFeed should not expose deliver alias')
  assert_eq(feed.push, nil, 'ExternalFeed should not expose push alias')
  feed:set('value')
  assert_eq(resource.value, 'value')
  feed:clear()
  assert_eq(resource.value, nil)

  local other = Runtime.new()
  local ok = pcall(function()
    other:deliver(feed, 'wrong-runtime')
  end)
  assert_eq(ok, false, 'external feed must remain bound to its runtime')
end

-- Source-named compatibility entry points are absent.
do
  local rt = Runtime.new()
  assert_eq(rt.events_source, nil, 'events_source compatibility method is removed')
end

-- Standard externally fed resources remain distinct kinds and feed lookup is stable.
do
  local signal = Signal.new('kind-signal')
  local events = EventQueue.new('kind-events')
  local clock = Clock.new('kind-clock')
  local readiness = Readiness.new('fd', 'read', 'kind-readiness')
  assert(signal._fibers_kind ~= events._fibers_kind)
  assert(events._fibers_kind ~= clock._fibers_kind)
  assert(clock._fibers_kind ~= readiness._fibers_kind)

  local rt = Runtime.new()
  assert_eq(
    rt:external_feed(signal),
    rt:external_feed(signal),
    'feed capability should be cached per runtime/resource'
  )
end

print('tests/test_external_resources.lua: ok')

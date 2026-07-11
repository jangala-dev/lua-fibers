-- Fine-grained invalidation tests for transaction-net frontiers.
package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

local Op = require('fibers.atoms.op')
local EventQueue = require('fibers.atoms.event_queue')
local Readiness = require('fibers.atoms.readiness')
local Clock = require('fibers.atoms.clock')
local Runtime = require('fibers.kernel.runtime')
local Debug = require('fibers.kernel.transaction_debug')
local UnsafeExternalMutation = require('fibers.internal.unsafe_external_mutation')
local Resources = require('fibers.kernel.resources')

local function fail(msg) error(msg, 2) end
local function assert_eq(a, b, msg) if a ~= b then fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a)) end end
local function assert_truthy(v, msg) if not v then fail(msg or 'expected truthy') end end
local function assert_false(v, msg) if v then fail(msg or 'expected false') end end
local function assert_world_valid(w, expected, msg)
  assert_eq(Debug.valid(w), expected, msg)
end
local function assert_observer_valid(o, expected, msg)
  assert_eq(Resources.observer_valid(o), expected, msg)
end

local function world_for(rt, op)
  local out = select(3, Debug.probe_world(rt, op, { retain = true }))
  assert_eq(out.tag, 'hit', 'expected a world')
  assert_truthy(out.world, 'expected hit world')
  assert_world_valid(out.world, true, 'world should be prepared and valid after probe')
  return out.world
end

-- A fallback world justified by queue A being empty is not invalidated by queue B.
do
  local rt = Runtime.new()
  local qa = EventQueue.new('fg-empty-a')
  local qb = EventQueue.new('fg-empty-b')
  local w = world_for(rt, qa:next_op():or_else(Op.always('fallback')))
  assert_truthy(w:has_retry(), 'fallback world should carry retry evidence')

  UnsafeExternalMutation.deliver(qb, 'unrelated')
  assert_world_valid(w, true, 'unrelated events arrival must not invalidate events-A absence')

  local ok, reason = w:commit(rt)
  assert_eq(ok, true, 'unrelated arrival should not prevent fallback commit')
  assert_eq(reason, nil)
end

-- The same fallback world is invalidated by arrival on the queue whose emptiness it observed.
do
  local rt = Runtime.new()
  local qa = EventQueue.new('fg-empty-related')
  local w = world_for(rt, qa:next_op():or_else(Op.always('fallback')))

  UnsafeExternalMutation.deliver(qa, 'now-present')
  assert_world_valid(w, false, 'related events arrival must invalidate events-empty absence')

  local ok, reason = w:commit(rt)
  assert_eq(ok, false, 'invalidated fallback must not commit')
  assert_eq(reason, 'invalidated-world')
end

-- A prepared queue-head consumer remains valid across a tail push.
do
  local rt = Runtime.new()
  local q = EventQueue.new('fg-head-tail')
  UnsafeExternalMutation.deliver(q, 'head')

  local w = world_for(rt, q:next_op())
  UnsafeExternalMutation.deliver(q, 'tail')
  assert_world_valid(w, true, 'tail push must not invalidate a prepared head consumer')

  local ok = w:commit(rt)
  assert_eq(ok, true, 'head consumer should commit after tail push')

  local w2 = world_for(rt, q:next_op())
  local vals = w2:run_wraps_for(rt, 1)
  assert_eq(vals[1], 'tail', 'tail item should remain after committed head consume')
end

-- A prepared queue-head consumer is invalidated by a competing consume of that head.
do
  local rt = Runtime.new()
  local q = EventQueue.new('fg-head-consume')
  UnsafeExternalMutation.deliver(q, 'one')

  local w1 = world_for(rt, q:next_op())
  local w2 = world_for(rt, q:next_op())
  assert_world_valid(w1, true)
  assert_world_valid(w2, true)

  assert_eq(w2:commit(rt), true, 'competing consumer should commit')
  assert_world_valid(w1, false, 'head consume must invalidate other prepared head consumers')
  local ok, reason = w1:commit(rt)
  assert_eq(ok, false)
  assert_eq(reason, 'invalidated-world')
end

-- Read and write readiness frontiers are independent.
do
  local rt = Runtime.new()
  local src = Readiness.new('fd-1', 'read', 'fg-readiness')
  local w = world_for(rt, src:readable_op():or_else(Op.always('fallback')))

  UnsafeExternalMutation.deliver(src, 'write', true)
  assert_world_valid(w, true, 'write readiness must not invalidate read absence')

  UnsafeExternalMutation.deliver(src, 'read', true)
  assert_world_valid(w, false, 'read readiness must invalidate read absence')
end

-- Clock-before observations invalidate exactly when their deadline matures.
do
  local now = 0
  local rt = Runtime.new({ host = { now = function() return now end } })
  local clock = Clock.new('fg-clock')
  local w = world_for(rt, clock:at_op(5):or_else(Op.always('fallback')))

  now = 4
  Resources.invalidate_matured_deadline_frontiers(rt)
  assert_world_valid(w, true, 'clock-before frontier should remain valid before deadline')

  now = 5
  Resources.invalidate_matured_deadline_frontiers(rt)
  assert_world_valid(w, false, 'clock-before frontier should invalidate at deadline')
end

-- Bounded miss caches are invalidated by observed frontiers, not unrelated source mutation.
do
  local rt = Runtime.new()
  local qa = EventQueue.new('fg-cache-a')
  local qb = EventQueue.new('fg-cache-b')
  local got
  rt:spawn_raw(function() got = rt:perform(qa:next_op()) end, 'fg-cache-waiter')

  for _ = 1, 20 do
    rt:step({ max_work = 1 })
    if Debug.wait_cache(rt) then break end
  end

  assert_truthy(Debug.wait_cache(rt), 'expected bounded miss cache')
  assert_truthy(Debug.wait_cache_observer(rt), 'bounded miss cache should own an observer')
  assert_observer_valid(Debug.wait_cache_observer(rt), true)

  UnsafeExternalMutation.deliver(qb, 'unrelated')
  assert_observer_valid(Debug.wait_cache_observer(rt), true, 'unrelated source should not invalidate miss cache')

  UnsafeExternalMutation.deliver(qa, 'payload')
  assert_observer_valid(Debug.wait_cache_observer(rt), false, 'observed events arrival should invalidate miss cache')

  for _ = 1, 20 do
    rt:step({ max_work = 1 })
    if got then break end
  end
  assert_eq(got, 'payload', 'runtime should restart from invalidated cache and consume arrival')
end

print('tests/test_frontier_invalidation.lua: ok')

-- Fine-grained invalidation tests for transaction-net frontiers.
package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

local Op = require('fibers.base.op')
local Source = require('fibers.base.source')
local Runtime = require('fibers.kernel.runtime')
local Net = require('fibers.kernel.transaction_net')
local SourceState = require('fibers.internal.source_state')
local Resources = require('fibers.kernel.resources')

local function fail(msg) error(msg, 2) end
local function assert_eq(a, b, msg) if a ~= b then fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a)) end end
local function assert_truthy(v, msg) if not v then fail(msg or 'expected truthy') end end
local function assert_false(v, msg) if v then fail(msg or 'expected false') end end

local function world_for(rt, op)
  local solver = Net.Solver.new(rt, { [1] = { op = op, fiber = nil, attempt = {} } })
  local out = solver:find_commit_outcome()
  assert_eq(out.tag, 'hit', 'expected a world')
  assert_truthy(out.world, 'expected hit world')
  assert_eq(out.world.valid, true, 'world should be prepared and valid after probe')
  return out.world
end

-- A fallback world justified by queue A being empty is not invalidated by queue B.
do
  local rt = Runtime.new({ retain_prepared_worlds = true })
  local qa = Source.queue('fg-empty-a')
  local qb = Source.queue('fg-empty-b')
  local w = world_for(rt, qa:next_op():or_else(Op.always('fallback')))
  assert_truthy(w:has_absence(), 'fallback world should carry absence')

  SourceState.arrive(qb, 'unrelated')
  assert_eq(w.valid, true, 'unrelated queue arrival must not invalidate queue-A absence')

  local ok, reason = w:commit(rt)
  assert_eq(ok, true, 'unrelated arrival should not prevent fallback commit')
  assert_eq(reason, nil)
end

-- The same fallback world is invalidated by arrival on the queue whose emptiness it observed.
do
  local rt = Runtime.new({ retain_prepared_worlds = true })
  local qa = Source.queue('fg-empty-related')
  local w = world_for(rt, qa:next_op():or_else(Op.always('fallback')))

  SourceState.arrive(qa, 'now-present')
  assert_false(w.valid, 'related queue arrival must invalidate queue-empty absence')

  local ok, reason = w:commit(rt)
  assert_eq(ok, false, 'invalidated fallback must not commit')
  assert_eq(reason, 'invalidated-world')
end

-- A prepared queue-head consumer remains valid across a tail push.
do
  local rt = Runtime.new({ retain_prepared_worlds = true })
  local q = Source.queue('fg-head-tail')
  SourceState.arrive(q, 'head')

  local w = world_for(rt, q:next_op())
  SourceState.arrive(q, 'tail')
  assert_eq(w.valid, true, 'tail push must not invalidate a prepared head consumer')

  local ok = w:commit(rt)
  assert_eq(ok, true, 'head consumer should commit after tail push')

  local w2 = world_for(rt, q:next_op())
  local vals = w2:run_wraps_for(rt, 1)
  assert_eq(vals[1], 'tail', 'tail item should remain after committed head consume')
end

-- A prepared queue-head consumer is invalidated by a competing consume of that head.
do
  local rt = Runtime.new({ retain_prepared_worlds = true })
  local q = Source.queue('fg-head-consume')
  SourceState.arrive(q, 'one')

  local w1 = world_for(rt, q:next_op())
  local w2 = world_for(rt, q:next_op())
  assert_eq(w1.valid, true)
  assert_eq(w2.valid, true)

  assert_eq(w2:commit(rt), true, 'competing consumer should commit')
  assert_false(w1.valid, 'head consume must invalidate other prepared head consumers')
  local ok, reason = w1:commit(rt)
  assert_eq(ok, false)
  assert_eq(reason, 'invalidated-world')
end

-- Read and write readiness frontiers are independent.
do
  local rt = Runtime.new({ retain_prepared_worlds = true })
  local src = Source.readiness('fd-1', 'read', 'fg-readiness')
  local w = world_for(rt, src:readable_op():or_else(Op.always('fallback')))

  SourceState.arrive(src, 'write', true)
  assert_eq(w.valid, true, 'write readiness must not invalidate read absence')

  SourceState.arrive(src, 'read', true)
  assert_false(w.valid, 'read readiness must invalidate read absence')
end

-- Clock-before observations invalidate exactly when their deadline matures.
do
  local now = 0
  local rt = Runtime.new({ host = { now = function() return now end }, retain_prepared_worlds = true })
  local clock = Source.clock('fg-clock')
  local w = world_for(rt, clock:at_op(5):or_else(Op.always('fallback')))

  now = 4
  Resources.invalidate_matured_clock_frontiers(rt)
  assert_eq(w.valid, true, 'clock-before frontier should remain valid before deadline')

  now = 5
  Resources.invalidate_matured_clock_frontiers(rt)
  assert_false(w.valid, 'clock-before frontier should invalidate at deadline')
end

-- Bounded miss caches are invalidated by observed frontiers, not unrelated source mutation.
do
  local rt = Runtime.new({ retain_prepared_worlds = true })
  local qa = Source.queue('fg-cache-a')
  local qb = Source.queue('fg-cache-b')
  local got
  rt:spawn_raw(function() got = rt:perform(qa:next_op()) end, 'fg-cache-waiter')

  for _ = 1, 20 do
    rt:step({ max_work = 1 })
    if rt._net_wait_cache then break end
  end

  assert_truthy(rt._net_wait_cache, 'expected bounded miss cache')
  assert_truthy(rt._net_wait_cache.observer, 'bounded miss cache should own an observer')
  assert_eq(rt._net_wait_cache.observer.valid, true)

  SourceState.arrive(qb, 'unrelated')
  assert_eq(rt._net_wait_cache.observer.valid, true, 'unrelated source should not invalidate miss cache')

  SourceState.arrive(qa, 'payload')
  assert_false(rt._net_wait_cache.observer.valid, 'observed queue arrival should invalidate miss cache')

  for _ = 1, 20 do
    rt:step({ max_work = 1 })
    if got then break end
  end
  assert_eq(got, 'payload', 'runtime should restart from invalidated cache and consume arrival')
end

print('tests/test_frontier_invalidation.lua: ok')

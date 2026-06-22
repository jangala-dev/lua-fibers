-- Regression tests for removing the runtime-wide cursor epoch.
--
-- The only remaining invalidation sources should be:
--   * pending_signature for the waiting-root problem; and
--   * managed validity facts observed by cursors, caches and prepared worlds.
package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

local Op = require('fibers.base.op')
local Runtime = require('fibers.kernel.runtime')
local Source = require('fibers.base.source')
local SourceState = require('fibers.internal.source_state')
local Debug = require('fibers.kernel.transaction_debug')
local Resources = require('fibers.kernel.resources')

local function fail(msg) error(msg, 2) end
local function assert_eq(a, b, msg) if a ~= b then fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a)) end end
local function assert_truthy(v, msg) if not v then fail(msg or 'expected truthy') end end
local function assert_false(v, msg) if v then fail(msg or 'expected false') end end

local function drive_until_cache(rt, label)
  for _ = 1, 40 do
    rt:step({ max_work = 1 })
    local cache = Debug.wait_cache(rt)
    if cache and cache.observer then return cache end
  end
  fail('expected wait cache for ' .. tostring(label))
end

local function world_for(rt, id, op)
  local pending = Debug.new_pending(op, id)
  local out = Debug.solve(rt, pending)
  assert_eq(out.tag, 'hit', 'expected hit world')
  assert_truthy(out.world, 'expected prepared world')
  return out.world, pending
end

-- The old Runtime._epoch invalidation API should not exist.  Local
-- _validity_opaque fields on opaque resources are still allowed; this test is
-- specifically about the runtime-wide hammer.
do
  local rt = Runtime.new()
  assert_eq(rt._epoch, nil, 'runtime should not carry a broad invalidation epoch')
  assert_eq(rt._invalidate_cursor, nil, 'runtime should not expose broad cursor invalidation')
  assert_eq(rt._bump_epoch, nil, 'runtime should not expose broad epoch bumping')
end

-- Ready-queue movement is not a resource fact.  It must not dispose a wait
-- cache whose pending problem and observed facts are unchanged.
do
  local rt = Runtime.new()
  local q = Source.queue('no-epoch-ready-cache')
  local got
  rt:spawn_raw(function() got = rt:perform(q:next_op()) end, 'no-epoch-cache-waiter')
  local cache = drive_until_cache(rt, 'ready cache')
  local observer = cache.observer
  assert_truthy(observer, 'cache owns observer')
  assert_eq(Resources.observer_valid(observer), true)

  rt:spawn_raw(function() return 'ready-only' end, 'no-epoch-ready-only')

  assert_eq(Debug.wait_cache(rt), cache, 'spawning ready work must not discard the wait cache')
  assert_eq(Resources.observer_valid(observer), true, 'ready-queue movement must not invalidate observed queue absence')
  assert_eq(got, nil)
end

-- A committed world touching an unrelated resource must not clear an existing
-- cache.  The cache remains reusable until its pending signature or observed
-- resource facts actually change.
do
  local rt = Runtime.new()
  local qa = Source.queue('no-epoch-cache-a')
  local qb = Source.queue('no-epoch-cache-b')
  local got
  rt:spawn_raw(function() got = rt:perform(qa:next_op()) end, 'no-epoch-cache-a-waiter')
  local cache = drive_until_cache(rt, 'unrelated commit cache')
  local observer = cache.observer

  SourceState.arrive(qb, 'payload-b')
  local op = qb:next_op()
  local world, pending = world_for(rt, 99, op)
  local ok, reason = rt:_apply_net_world(world, pending)
  assert_eq(ok, true, 'unrelated ready world should commit')
  assert_eq(reason, nil)

  assert_eq(Debug.wait_cache(rt), cache, 'unrelated commit must not discard cache')
  assert_eq(Resources.observer_valid(observer), true, 'unrelated commit must not invalidate queue-A absence')
  assert_eq(got, nil)

  SourceState.arrive(qa, 'payload-a')
  assert_eq(Resources.observer_valid(observer), false, 'related queue arrival must still invalidate cache')
end

-- Waiting-root shape is still guarded, but by pending_signature rather than by
-- a broad epoch.  The old observer remains valid because no observed fact has
-- changed; the runtime rejects the cache only when solving the changed pending
-- problem.
do
  local rt = Runtime.new()
  local qa = Source.queue('no-epoch-sig-a')
  local qb = Source.queue('no-epoch-sig-b')
  rt:spawn_raw(function() rt:perform(qa:next_op()) end, 'no-epoch-sig-a-waiter')
  local cache = drive_until_cache(rt, 'signature cache')
  local observer = cache.observer

  rt:spawn_raw(function() rt:perform(qb:next_op()) end, 'no-epoch-sig-b-waiter')
  assert_eq(Debug.wait_cache(rt), cache, 'ready fibre alone must not discard cache before it joins the pending set')
  assert_eq(Resources.observer_valid(observer), true)

  rt:step({ max_work = 20 }) -- starts the second fibre; cache is still rejected lazily, not pre-emptively
  assert_eq(Resources.observer_valid(observer), true, 'starting another fibre must not poison resource observations')

  rt:step({ max_work = 20 }) -- now the changed pending set is solved and the old signature is rejected
  assert_eq(Resources.observer_valid(observer), true, 'pending-shape rejection must not poison resource observations')
  assert_false(Debug.wait_cache(rt) == cache, 'changed pending_signature must reject the old cache without using a runtime epoch')
end

print('tests/test_validity_no_global_epoch.lua: ok')

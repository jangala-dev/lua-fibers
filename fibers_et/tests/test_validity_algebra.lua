-- Managed validity algebra tests.
package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

local Validity = require('fibers.kernel.validity')
local Resources = require('fibers.kernel.resources')
local Debug = require('fibers.kernel.transaction_debug')
local Op = require('fibers.base.op')
local Source = require('fibers.base.source')
local SourceState = require('fibers.internal.source_state')
local Runtime = require('fibers.kernel.runtime')

local function fail(msg) error(msg, 2) end
local function assert_eq(a, b, msg) if a ~= b then fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a)) end end
local function assert_truthy(v, msg) if not v then fail(msg or 'expected truthy') end end

local function ctx_for(observer)
  return { observer = observer, observe_frontier = function(self, frontier) return frontier:observe(self.observer) end }
end

-- Scalar reads record a stamp; managed set invalidates lazily on validation.
do
  local s = Validity.scalar('a', 'validity-scalar')
  local obs = Resources.new_observer('test')
  assert_eq(s:get(ctx_for(obs)), 'a')
  assert_eq(Resources.observer_valid(obs), true)
  s:set('b')
  assert_eq(obs.valid, true, 'pull validation is lazy until checked')
  assert_eq(Resources.observer_valid(obs), false, 'managed scalar set invalidates observed fact')
end

-- Queue tail pushes do not invalidate a head observation, but head takes do.
do
  local q = Validity.queue('validity-queue')
  q:push('head')
  local obs = Resources.new_observer('head')
  assert_eq(q:peek(ctx_for(obs)), 'head')
  q:push('tail')
  assert_eq(Resources.observer_valid(obs), true, 'tail push must not invalidate head observation')
  q:take(1)
  assert_eq(Resources.observer_valid(obs), false, 'head take invalidates head observation')
end

-- Queue empty observations are invalidated when the queue becomes non-empty.
do
  local q = Validity.queue('validity-empty')
  local obs = Resources.new_observer('empty')
  assert_eq(q:peek(ctx_for(obs)), nil)
  q:push('payload')
  assert_eq(Resources.observer_valid(obs), false, 'push to empty invalidates empty observation')
end

-- Source fallback validity is driven by managed queue facts, not manual bump calls.
do
  local rt = Runtime.new()
  local q = Source.queue('validity-source')
  local got
  rt:spawn_raw(function() got = rt:perform(q:next_op():or_else(Op.always('fallback'))) end, 'validity-source-fallback')
  for _ = 1, 20 do if got then break end; rt:step({ max_work = 5 }) end
  assert_eq(got, 'fallback')

  local q2 = Source.queue('validity-source-pending')
  local got2
  rt = Runtime.new()
  rt:spawn_raw(function() got2 = rt:perform(q2:next_op()) end, 'validity-source-pending-waiter')
  for _ = 1, 5 do rt:step({ max_work = 1 }) end
  assert_truthy(Debug.wait_cache_observer(rt), 'expected a bounded wait cache')
  SourceState.arrive(q2, 'payload')
  assert_eq(Resources.observer_valid(Debug.wait_cache_observer(rt)), false, 'managed queue feed invalidates empty wait cache')
  for _ = 1, 20 do if got2 then break end; rt:step({ max_work = 1 }) end
  assert_eq(got2, 'payload')
end

-- Managed signals are latched, non-consuming facts.
do
  local rt = Runtime.new()
  local sig = Source.signal('validity-signal')
  SourceState.arrive(sig, 'latched')
  local a, b
  rt:spawn_raw(function() a = rt:perform(sig:wait_op()) end, 'validity-signal-a')
  rt:spawn_raw(function() b = rt:perform(sig:wait_op()) end, 'validity-signal-b')
  for _ = 1, 10 do if a and b then break end; rt:step({ max_work = 10 }) end
  assert_eq(a, 'latched')
  assert_eq(b, 'latched')
end


-- Map separates membership, value and whole-structure validity.
do
  local m = Validity.map('validity-map')
  local missing = Resources.new_observer('map-missing')
  assert_eq(m:get(ctx_for(missing), 'a'), nil)
  m:set('a', 1)
  assert_eq(Resources.observer_valid(missing), false, 'adding key invalidates missing membership observation')

  local membership = Resources.new_observer('map-membership')
  assert_eq(m:contains(ctx_for(membership), 'a'), true)
  m:set('a', 2)
  assert_eq(Resources.observer_valid(membership), true, 'value update must not invalidate membership-only observation')

  local value = Resources.new_observer('map-value')
  assert_eq(m:get(ctx_for(value), 'a'), 2)
  m:set('a', 3)
  assert_eq(Resources.observer_valid(value), false, 'value update invalidates value observation')

  local structure = Resources.new_observer('map-structure')
  local seen = 0
  for _ in m:pairs(ctx_for(structure)) do seen = seen + 1 end
  assert_eq(seen, 1)
  m:set('b', 4)
  assert_eq(Resources.observer_valid(structure), false, 'adding key invalidates structure observation')
end

-- Set is the membership-specialised form of Map.
do
  local s = Validity.set('validity-set')
  local obs = Resources.new_observer('set')
  assert_eq(s:contains(ctx_for(obs), 'member'), false)
  s:add('member')
  assert_eq(Resources.observer_valid(obs), false, 'set add invalidates membership observation')
end

-- Claim is an ownership-specialised managed keyspace.
do
  local claims = Validity.claim('validity-claim')
  local obs = Resources.new_observer('claim-free')
  assert_eq(claims:is_free(ctx_for(obs), 'slot'), true)
  claims:claim('slot', 'owner-a')
  assert_eq(Resources.observer_valid(obs), false, 'claim acquisition invalidates free observation')

  local owner = Resources.new_observer('claim-owner')
  assert_eq(claims:owner(ctx_for(owner), 'slot'), 'owner-a')
  local ok, why = claims:release('slot', 'owner-b')
  assert_eq(ok, false)
  assert_eq(why, 'not-owner')
  assert_eq(Resources.observer_valid(owner), true, 'failed release does not invalidate owner observation')
  assert_eq(claims:release('slot', 'owner-a'), true)
  assert_eq(Resources.observer_valid(owner), false, 'release invalidates owner observation')
end

-- Derived views have no independent stamp; they record the facts their body reads.
do
  local gate = Validity.scalar(true, 'validity-derived-gate')
  local members = Validity.set('validity-derived-members')
  members:add('ready')
  local view = Validity.derived(function(ctx)
    return gate:get(ctx) and members:contains(ctx, 'ready')
  end, 'validity-derived')
  local obs = Resources.new_observer('derived')
  assert_eq(view:get(ctx_for(obs)), true)
  members:add('unrelated')
  assert_eq(Resources.observer_valid(obs), true, 'unobserved derived dependency must not invalidate')
  gate:set(false)
  assert_eq(Resources.observer_valid(obs), false, 'derived view invalidates through observed scalar dependency')
end

print('tests/test_validity_algebra.lua: ok')

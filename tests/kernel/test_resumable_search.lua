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
local Rendezvous = require('fibers.resource.rendezvous')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error(
      (message or 'assertion failed')
        .. ': expected '
        .. tostring(expected)
        .. ', got '
        .. tostring(actual),
      2
    )
  end
end

-- A suspended fallback proof retains its exact branch position.  The guard and
-- fallback callback are each entered once even though the driver supplies one
-- search round at a time.
do
  local rt = Runtime.new({ plan_reuse = false })
  local preferred_calls, fallback_calls = 0, 0
  local result
  local op = Op.guard(function()
    preferred_calls = preferred_calls + 1
    return Op.never()
  end):or_else(Op.guard(function()
    fallback_calls = fallback_calls + 1
    return Op.always('fallback')
  end))

  rt:spawn_raw(function()
    result = rt:perform(op)
  end, 'resumable-fallback')
  assert_eq(rt:step({ max_work = 1 }).kind, 'started')

  local saw_budget = false
  for _ = 1, 12 do
    local status = rt:step({ max_work = 1 })
    if status.kind == 'budget' then
      saw_budget = true
    end
    if status.tag == 'found' then
      break
    end
  end
  rt:run()

  assert(saw_budget, 'resumable fallback should cross a budget boundary')
  assert_eq(result, 'fallback')
  assert_eq(preferred_calls, 1, 'preferred guard must not be replayed after suspension')
  assert_eq(fallback_calls, 1, 'fallback guard must be entered once')
  if rt.machine_name == 'trail' then
    assert_eq(rt.stats.plans, 1, 'one proof session should survive all bounded advances')
  end
end

-- Two rendezvous focuses may each acquire a suspended session, but repeated
-- bounded advances must resume those sessions rather than constructing plans
-- afresh on every driver call.
do
  local rt = Runtime.new({ plan_reuse = false })
  local channel = Rendezvous.new('resumable-rendezvous')
  local got, sent
  rt:spawn_raw(function()
    got = rt:perform(channel:get_op())
  end, 'receiver')
  rt:spawn_raw(function()
    sent = rt:perform(channel:put_op('value'))
  end, 'sender')

  local found = false
  for _ = 1, 20 do
    local status = rt:step({ max_work = 1 })
    if status.tag == 'found' then
      found = true
      break
    end
  end
  assert(found, 'bounded rendezvous should eventually commit')
  rt:run()
  assert_eq(got, 'value')
  assert_eq(sent, true)
  if rt.machine_name == 'trail' then
    assert_eq(
      rt.stats.plans,
      2,
      'bounded rendezvous should retain one session per focus rather than restart'
    )
  end
end

-- A frontier change invalidates retained speculative state before it is reused.
do
  local rt = Runtime.new({ plan_reuse = false, instrumentation = true })
  local channel = Rendezvous.new('resumable-invalidation')
  local got
  rt:spawn_raw(function()
    got = rt:perform(channel:get_op())
  end, 'receiver')
  rt:step({ max_work = 1 }) -- start the receiver
  rt:step({ max_work = 1 }) -- suspend its proof
  local plans_before = rt.stats.plans

  rt:spawn_raw(function()
    rt:perform(channel:put_op('new'))
  end, 'late-sender')
  local found = false
  for _ = 1, 20 do
    local status = rt:step({ max_work = 1 })
    if status.tag == 'found' then
      found = true
      break
    end
  end
  assert(found, 'changed frontier should be searched afresh and commit')
  rt:run()
  assert_eq(got, 'new')
  assert(rt.stats.plans > plans_before, 'frontier change should require a new proof')
  if rt.machine_name == 'trail' then
    local snapshot = rt:instrumentation_snapshot()
    assert(
      (snapshot.counters.search_session_invalidations or 0) >= 1,
      'session invalidation should be observable'
    )
  end
end

-- Session dependency vectors ignore unrelated dependency buckets but reject a
-- change which can alter the suspended frontier.
do
  local rt = Runtime.new({ machine = 'trail', plan_reuse = false, instrumentation = true })
  local primary = Rendezvous.new('precise-session-primary')
  local unrelated = Rendezvous.new('precise-session-unrelated')
  local alternatives = {}
  for i = 1, 16 do
    alternatives[i] = primary:get_op()
  end

  rt:spawn_raw(function()
    rt:perform(Op.choice(alternatives))
  end, 'precise-primary')
  rt:_pump()
  local focus = rt.pending[1].id
  local _, _, unknown = rt:_find_candidate(focus, 1)
  assert_eq(unknown, true, 'initial proof should suspend')
  local plans = rt.stats.plans

  rt:spawn_raw(function()
    rt:perform(unrelated:get_op())
  end, 'precise-unrelated')
  rt:_start_one()
  rt:_find_candidate(focus, 1)
  assert_eq(
    rt.stats.plans,
    plans,
    'unrelated dependency admission should preserve the suspended session'
  )

  rt:spawn_raw(function()
    rt:perform(primary:put_op('ready'))
  end, 'precise-related')
  rt:_start_one()
  rt:_find_candidate(focus, 1)
  assert(rt.stats.plans > plans, 'a possible partner should invalidate the suspended session')
end

-- A stable blocked primitive becomes a residual seed.  Admission of a matching
-- participant reopens that frontier without constructing another production
-- search session or replaying the primitive prefix.
do
  local rt = Runtime.new({ machine = 'trail', instrumentation = true, plan_reuse_threshold = 1 })
  local channel = Rendezvous.new('residual-seed-rendezvous')
  local got
  rt:spawn_raw(function()
    got = rt:perform(channel:get_op())
  end, 'seed-receiver')
  assert_eq(rt:run().tag, 'quiescent')
  local sessions = rt.stats.search_sessions

  rt:spawn_raw(function()
    rt:perform(channel:put_op('seeded'))
  end, 'seed-sender')
  assert_eq(rt:run().tag, 'found')
  assert_eq(got, 'seeded')
  if rt.machine_name == 'trail' then
    assert_eq(
      rt.stats.search_sessions,
      sessions,
      'matching admission should reopen the residual seed rather than construct a session'
    )
    local counters = rt:instrumentation_snapshot().counters
    assert((counters.residual_seed_reopens or 0) > 0, 'residual seed reopen was not recorded')
  end
end

-- Witness cursors are retained at their current alternative rather than being
-- reopened after each budget boundary.
do
  local IR = require('fibers.internal.kernel.ir')
  local Store = require('fibers.internal.kernel.store')
  local Kind = { name = 'resumable-witness' }
  local location = Store.new_location({
    name = 'resumable-witness-location',
    merge = 'machine',
    domain = 'plain',
    value = 0,
  })
  local opened, next_calls = 0, 0
  local program = IR.witness_transition({
    location = location,
    cursor = function()
      opened = opened + 1
      local done = false
      return {
        next = function()
          next_calls = next_calls + 1
          if done then
            return nil
          end
          done = true
          return { value = 1, result = Op._pack('witness'), writes = true }
        end,
      }
    end,
  })
  local resource = { _fibers_kind = Kind }
  local rt = Runtime.new({ plan_reuse = false })
  local result
  rt:spawn_raw(function()
    result = rt:perform(Op._resource(resource, Kind, program))
  end, 'resumable-witness')

  local found = false
  for _ = 1, 12 do
    local status = rt:step({ max_work = 1 })
    if status.tag == 'found' then
      found = true
      break
    end
  end
  assert(found, 'bounded witness search should commit')
  rt:run()
  assert_eq(result, 'witness')
  if rt.machine_name == 'trail' then
    assert_eq(opened, 1, 'witness cursor should be opened once across suspension')
    assert_eq(next_calls, 1, 'witness cursor should retain its current alternative')
  end
end

print('tests/test_resumable_search.lua: ok')

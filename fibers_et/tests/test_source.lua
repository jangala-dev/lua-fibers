-- Source semantics tests.
package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

local Op = require('fibers.base.op')
local Runtime = require('fibers.kernel.runtime')
local Source = require('fibers.base.source')
local Channel = require('fibers.base.channel')

local function fail(msg) error(msg, 2) end
local function assert_eq(a, b, msg) if a ~= b then fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a)) end end
local function assert_status(st, tag, msg) if not st or st.tag ~= tag then fail((msg or 'status mismatch') .. ': expected ' .. tag .. ', got ' .. tostring(st and st.tag)) end end

-- Not ready now, but fallback is available now: fallback commits.
do
  local ev = Source.signal('unset')
  local rt = Runtime.new()
  local got
  rt:spawn_raw(function() got = rt:perform(ev:wait_op():or_else(Op.always('fallback'))) end, 'fallback-on-not-ready')
  assert_status(rt:run(), 'found')
  assert_eq(got, 'fallback')
end

-- Not ready now, no fallback: runtime reports pending wake interests, not absence.
do
  local ev = Source.signal('pending')
  local rt = Runtime.new()
  local got
  rt:spawn_raw(function() got = rt:perform(ev:wait_op()) end, 'pending-no-fallback')
  local st = rt:run()
  assert_status(st, 'pending')
  assert_eq(got, nil)
  assert(st.waits and #st.waits == 1, 'expected one wake interest')
end

-- Ready now beats fallback.
do
  local ev = Source.signal('ready')
  local rt = Runtime.new()
  rt:arrive(ev, 'payload')
  local got
  rt:spawn_raw(function() got = rt:perform(ev:wait_op():or_else(Op.always('fallback'))) end, 'ready-beats-fallback')
  assert_status(rt:run(), 'found')
  assert_eq(got, 'payload')
end

-- Ready external value still participates in the global rendezvous search.
do
  local ev = Source.signal('ready-with-rendezvous')
  local ch = Channel.new('external-plus-rendezvous')
  local rt = Runtime.new()
  rt:arrive(ev, 'payload')
  local receiver, sender
  rt:spawn_raw(function()
    receiver = rt:perform(
      ev:wait_op():and_then(function(v)
        return ch:get_op():map(function(x) return v .. ':' .. x end)
      end):or_else(Op.always('fallback')))
  end, 'receiver')
  rt:spawn_raw(function() sender = rt:perform(ch:put_op('rv')) end, 'sender')
  assert_status(rt:run(), 'found')
  assert_eq(receiver, 'payload:rv')
  assert_eq(sender, true)
end

-- Clock sources use host time and report a time wait while the deadline is future.
do
  local now = 0
  local clock = Source.clock('source-clock-test')
  local rt = Runtime.new({ host = { now = function() return now end } })
  local ok, observed
  rt:spawn_raw(function() ok, observed = rt:perform(clock:after_op(5)) end, 'clock-waiter')
  local st = rt:run()
  assert_status(st, 'pending')
  assert(st.waits and #st.waits == 1, 'expected one time wait')
  now = 5
  st = rt:step()
  assert_status(st, 'found')
  assert_eq(ok, true)
  assert_eq(observed, 5)
end


-- Runtime:arrive is the host/source boundary for bounded stepping.
do
  local ev = Source.signal('bounded-arrival')
  local rt = Runtime.new()
  local got
  rt:spawn_raw(function() got = rt:perform(ev:wait_op()) end, 'bounded-arrival-waiter')
  for _ = 1, 5 do rt:step({ max_work = 1 }) end
  rt:arrive(ev, 'arrived')
  local st
  for _ = 1, 20 do
    st = rt:step({ max_work = 1 })
    if got then break end
  end
  assert_eq(got, 'arrived')
  assert(st and (st.tag == 'found' or st.tag == 'pending'), 'expected bounded stepping to resume after arrival')
end

-- Queue sources consume occurrences only if the selected transaction commits.
do
  local q = Source.queue('queue-source')
  local rt = Runtime.new()
  rt:arrive(q, 'a')
  rt:arrive(q, 'b', 'bee')
  local first, second_a, second_b
  rt:spawn_raw(function()
    first = rt:perform(q:next_op())
    second_a, second_b = rt:perform(q:next_op())
  end, 'queue-consumer')
  assert_status(rt:run(), 'found')
  assert_eq(first, 'a')
  assert_eq(second_a, 'b')
  assert_eq(second_b, 'bee')
end

-- A losing queue branch does not consume the occurrence.
do
  local q = Source.queue('queue-loser')
  local rt = Runtime.new()
  rt:arrive(q, 'kept')
  local got, remaining
  rt:spawn_raw(function()
    got = rt:perform(Op.choice(
      q:next_op():and_then(function() return Op.never() end),
      Op.always('winner')
    ))
    remaining = rt:perform(q:next_op())
  end, 'queue-loser-consumer')
  assert_status(rt:run(), 'found')
  assert_eq(got, 'winner')
  assert_eq(remaining, 'kept')
end



-- Bounded clock cursors are invalidated by observation once the observed deadline matures.
do
  local now = 0
  local clock = Source.clock('bounded-clock-observation')
  local rt = Runtime.new({ host = { now = function() return now end } })
  local ok, observed
  rt:spawn_raw(function() ok, observed = rt:perform(clock:after_op(5)) end, 'bounded-clock-waiter')
  for _ = 1, 5 do rt:step({ max_work = 1 }) end
  assert_eq(ok, nil, 'sleep should still be pending before deadline')
  now = 5
  local st
  for _ = 1, 30 do
    st = rt:step({ max_work = 1 })
    if ok then break end
  end
  assert_eq(ok, true, 'bounded clock wait should commit after deadline without explicit invalidation')
  assert_eq(observed, 5)
end

-- Observation also protects source observations if a producer bypasses the Runtime epoch.
do
  local SourceState = require('fibers.internal.source_state')
  local ev = Source.signal('bounded-source-observation')
  local rt = Runtime.new()
  local got
  rt:spawn_raw(function() got = rt:perform(ev:wait_op()) end, 'bounded-source-observation-waiter')
  for _ = 1, 5 do rt:step({ max_work = 1 }) end
  SourceState.arrive(ev, 'direct') -- deliberate internal mutation; no rt epoch bump
  local st
  for _ = 1, 30 do
    st = rt:step({ max_work = 1 })
    if got then break end
  end
  assert_eq(got, 'direct', 'source version observation should invalidate stale bounded cursor')
end

-- Fallback opened because a deadline was absent-now must be rechecked if the deadline matures before commit.
do
  local now = 0
  local clock = Source.clock('bounded-clock-or-else-observation')
  local rt = Runtime.new({ host = { now = function() return now end } })
  local got
  rt:spawn_raw(function()
    got = rt:perform(clock:at_op(5):map(function() return 'time' end):or_else(Op.always('fallback')))
  end, 'bounded-clock-or-else')
  rt:step({ max_work = 1 }) -- build candidates, observing now < 5 and opening fallback
  now = 5
  local st
  for _ = 1, 30 do
    st = rt:step({ max_work = 1 })
    if got then break end
  end
  assert_eq(got, 'time', 'matured primary should beat stale fallback proof')
end

print('tests/test_source.lua: ok')

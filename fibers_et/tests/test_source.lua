-- Source semantics tests.
package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local Source = require('fibers.source')
local Channel = require('fibers.channel')

local function fail(msg) error(msg, 2) end
local function assert_eq(a, b, msg) if a ~= b then fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a)) end end
local function assert_status(st, tag, msg) if not st or st.tag ~= tag then fail((msg or 'status mismatch') .. ': expected ' .. tag .. ', got ' .. tostring(st and st.tag)) end end

-- Not ready now, but fallback is available now: fallback commits.
do
  local ev = Source.manual('unset')
  local rt = Runtime.new()
  local got
  rt:spawn_raw(function() got = rt:perform(ev:next_op(Op):or_else(Op.always('fallback'))) end, 'fallback-on-not-ready')
  assert_status(rt:run(), 'found')
  assert_eq(got, 'fallback')
end

-- Not ready now, no fallback: runtime reports pending wake interests, not absence.
do
  local ev = Source.manual('pending')
  local rt = Runtime.new()
  local got
  rt:spawn_raw(function() got = rt:perform(ev:next_op(Op)) end, 'pending-no-fallback')
  local st = rt:run()
  assert_status(st, 'pending')
  assert_eq(got, nil)
  assert(st.waits and #st.waits == 1, 'expected one wake interest')
end

-- Ready now beats fallback.
do
  local ev = Source.manual('ready')
  ev:emit('payload')
  local rt = Runtime.new()
  local got
  rt:spawn_raw(function() got = rt:perform(ev:next_op(Op):or_else(Op.always('fallback'))) end, 'ready-beats-fallback')
  assert_status(rt:run(), 'found')
  assert_eq(got, 'payload')
end

-- Ready external value still participates in the global rendezvous search.
do
  local ev = Source.manual('ready-with-rendezvous')
  ev:emit('payload')
  local ch = Channel.new('external-plus-rendezvous')
  local rt = Runtime.new()
  local receiver, sender
  rt:spawn_raw(function()
    receiver = rt:perform(
      ev:next_op(Op):and_then(function(v)
        return ch:get_op(Op):map(function(x) return v .. ':' .. x end)
      end):or_else(Op.always('fallback')))
  end, 'receiver')
  rt:spawn_raw(function() sender = rt:perform(ch:put_op(Op, 'rv')) end, 'sender')
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

print('tests/test_source.lua: ok')

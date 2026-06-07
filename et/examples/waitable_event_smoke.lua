package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local Event = require('fibers.resources.event')
local Channel = require('fibers.resources.channel')

local function fail(msg) error(msg, 2) end
local function assert_eq(a, b, msg) if a ~= b then fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a)) end end
local function assert_status(st, tag) if not st or st.tag ~= tag then fail('expected ' .. tag .. ', got ' .. tostring(st and st.tag)) end end

-- Not ready now, but fallback is available now: fallback commits.
do
  local ev = Event.new('unset')
  local rt = Runtime.new()
  local got
  rt:spawn(function() got = rt:perform(ev:wait_op(Op):or_else(Op.always('fallback'))) end, 'fallback-on-not-ready')
  assert_status(rt:run(), 'found')
  assert_eq(got, 'fallback')
end

-- Not ready now, no fallback: runtime reports pending wake interests, not absence.
do
  local ev = Event.new('pending')
  local rt = Runtime.new()
  local got
  rt:spawn(function() got = rt:perform(ev:wait_op(Op)) end, 'pending-no-fallback')
  local st = rt:run()
  assert_status(st, 'pending')
  assert_eq(got, nil)
  assert(st.waits and #st.waits == 1, 'expected one wake interest')
end

-- Ready now beats fallback.
do
  local ev = Event.new('ready')
  ev:set('payload')
  local rt = Runtime.new()
  local got
  rt:spawn(function() got = rt:perform(ev:wait_op(Op):or_else(Op.always('fallback'))) end, 'ready-beats-fallback')
  assert_status(rt:run(), 'found')
  assert_eq(got, 'payload')
end

-- Ready external value still participates in the global rendezvous search.
do
  local ev = Event.new('ready-with-rendezvous')
  ev:set('payload')
  local ch = Channel.new('external-plus-rendezvous')
  local rt = Runtime.new()
  local receiver, sender
  rt:spawn(function()
    receiver = rt:perform(
      ev:wait_op(Op):and_then(function(v)
        return ch:get_op(Op):map(function(x) return v .. ':' .. x end)
      end):or_else(Op.always('fallback')))
  end, 'receiver')
  rt:spawn(function() sender = rt:perform(ch:put_op(Op, 'rv')) end, 'sender')
  assert_status(rt:run(), 'found')
  assert_eq(receiver, 'payload:rv')
  assert_eq(sender, true)
end

print('waitable event semantics: ok')

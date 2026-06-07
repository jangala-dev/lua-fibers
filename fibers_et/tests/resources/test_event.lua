-- Waitable event resource contract tests.

package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local Event = require('fibers.resources.event')
local Channel = require('fibers.resources.channel')
local H = require('tests.resources.test_helpers')

local function test_not_ready_with_fallback_commits_fallback()
  local ev = Event.new('unset')
  local rt = Runtime.new()
  local got
  rt:spawn(function() got = rt:perform(ev:wait_op(Op):or_else(Op.always('fallback'))) end, 'fallback-on-not-ready')
  H.assert_status(rt:run(), 'found')
  H.assert_eq(got, 'fallback')
end

local function test_not_ready_without_fallback_reports_pending_wake_interest()
  local ev = Event.new('pending')
  local rt = Runtime.new()
  local got
  rt:spawn(function() got = rt:perform(ev:wait_op(Op)) end, 'pending-no-fallback')
  local st = rt:run()
  H.assert_status(st, 'pending')
  H.assert_eq(got, nil)
  H.assert_truthy(st.waits and #st.waits == 1, 'expected one wake interest')
end

local function test_ready_now_beats_fallback()
  local ev = Event.new('ready')
  ev:set('payload')
  local rt = Runtime.new()
  local got
  rt:spawn(function() got = rt:perform(ev:wait_op(Op):or_else(Op.always('fallback'))) end, 'ready-beats-fallback')
  H.assert_status(rt:run(), 'found')
  H.assert_eq(got, 'payload')
end

local function test_ready_external_value_still_participates_in_global_rendezvous_search()
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
  H.assert_status(rt:run(), 'found')
  H.assert_eq(receiver, 'payload:rv')
  H.assert_eq(sender, true)
end

local tests = {
  test_not_ready_with_fallback_commits_fallback,
  test_not_ready_without_fallback_reports_pending_wake_interest,
  test_ready_now_beats_fallback,
  test_ready_external_value_still_participates_in_global_rendezvous_search,
}

for i = 1, #tests do tests[i]() end
print('tests/resources/test_event.lua: ok')

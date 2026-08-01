-- Waitable event resource contract tests.

package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

local External = require('fibers.embed.external')
local Op = require('fibers.op')
local Runtime = require('fibers.runtime')

local function deliver(rt, resource, ...)
  return External.external_feed(rt, resource):set(...)
end
local Signal = require('fibers.resource.signal')
local Rendezvous = require('fibers.resource.rendezvous')
local H = require('tests.resources.helpers')

local function test_not_ready_with_fallback_commits_fallback()
  local ev = Signal.new('unset')
  local rt = Runtime.new()
  local got
  rt:spawn_raw(function()
    got = rt:perform(ev:wait_op():or_else(Op.always('fallback')))
  end, 'fallback-on-not-ready')
  H.assert_status(rt:run(), 'found')
  H.assert_eq(got, 'fallback')
end

local function test_not_ready_without_fallback_reports_pending_wake_interest()
  local ev = Signal.new('pending')
  local rt = Runtime.new()
  local got
  rt:spawn_raw(function()
    got = rt:perform(ev:wait_op())
  end, 'pending-no-fallback')
  local st = rt:run()
  H.assert_status(st, 'pending')
  H.assert_eq(got, nil)
  H.assert_truthy(st.interests and #st.interests == 1, 'expected one wake interest')
end

local function test_ready_now_beats_fallback()
  local ev = Signal.new('ready')
  local rt = Runtime.new()
  deliver(rt, ev, 'payload')
  local got
  rt:spawn_raw(function()
    got = rt:perform(ev:wait_op():or_else(Op.always('fallback')))
  end, 'ready-beats-fallback')
  H.assert_status(rt:run(), 'found')
  H.assert_eq(got, 'payload')
end

local function test_ready_external_value_still_participates_in_global_rendezvous_search()
  local ev = Signal.new('ready-with-rendezvous')
  local ch = Rendezvous.new('external-plus-rendezvous')
  local rt = Runtime.new()
  deliver(rt, ev, 'payload')
  local receiver, sender
  rt:spawn_raw(function()
    receiver = rt:perform(ev:wait_op()
      :and_then(Op.guard(function(v)
        return ch:get_op():map(function(x)
          return v .. ':' .. x
        end)
      end))
      :or_else(Op.always('fallback')))
  end, 'receiver')
  rt:spawn_raw(function()
    sender = rt:perform(ch:put_op('rv'))
  end, 'sender')
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

for i = 1, #tests do
  tests[i]()
end
print('tests/resources/test_event.lua: ok')

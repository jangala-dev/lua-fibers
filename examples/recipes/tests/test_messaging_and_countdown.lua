-- Pulse, CountdownLatch and Mailbox compound facilities over base atomics.

package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

local fibers = require('fibers')
local FibersMailbox = require('fibers.mailbox')
local FibersPulse = require('fibers.pulse')
local FibersChannel = require('fibers.channel')
local CountdownLatch = require('examples.recipes.countdown_latch')
local Op = require('fibers.op')
local Runtime = require('fibers.runtime')

local function fail(msg)
  error(msg, 2)
end
local function assert_eq(actual, expected, msg)
  if actual ~= expected then
    fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual))
  end
end
local function assert_status(status, tag, msg)
  if not status or status.tag ~= tag then
    fail(
      (msg or 'status mismatch')
        .. ': expected '
        .. tostring(tag)
        .. ', got '
        .. tostring(status and status.tag)
    )
  end
end
local function assert_not_found(status, msg)
  if status and status.tag == 'found' then
    fail(msg or 'option unexpectedly committed')
  end
end
local function new_runtime(opts)
  return Runtime.new(opts or {})
end

local function test_top_level_exports()
  assert_eq(type(FibersPulse.new), 'function', 'Pulse export')
  assert_eq(type(CountdownLatch.new), 'function', 'CountdownLatch export')
  assert_eq(type(FibersMailbox.new), 'function', 'Mailbox export')
  assert_eq(type(FibersMailbox.reject_newest), 'function', 'Mailbox reject_newest export')
  assert_eq(type(FibersMailbox.drop_oldest), 'function', 'Mailbox drop_oldest export')
  assert_eq(type(FibersChannel.new), 'function', 'Channel export')
end

local function test_pulse_signal_and_changed()
  local p = FibersPulse.new()
  local rt = new_runtime()
  local version
  rt:spawn_raw(function()
    version = rt:perform(p:signal_op())
  end):label('pulse-signal')
  assert_status(rt:run(), 'found')
  assert_eq(version, 1)

  local rt2 = new_runtime()
  local seen, reason
  rt2:spawn_raw(function()
    seen, reason = rt2:perform(p:changed_op(0))
  end):label('pulse-changed')
  assert_status(rt2:run(), 'found')
  assert_eq(seen, 1)
  assert_eq(reason, nil)
end

local function test_pulse_waits_and_close_wakes()
  local p = FibersPulse.new()
  local rt = new_runtime({ quiet_deadlock = true })
  local done = false
  local version, reason
  rt:spawn_raw(function()
    version, reason = rt:perform(p:changed_op(0))
    done = true
  end):label('pulse-waiter')
  assert_status(rt:run(), 'quiescent')
  assert_eq(done, false)
  rt:spawn_raw(function()
    rt:perform(p:close_op('shutdown'))
  end):label('pulse-close')
  assert_status(rt:run(), 'found')
  assert_eq(done, true)
  assert_eq(version, nil)
  assert_eq(reason, 'shutdown')
end

local function test_pulse_losing_signal_branch_does_not_mutate()
  local p = FibersPulse.new()
  local rt = new_runtime({ choice_seed = 2 })
  local got
  rt:spawn_raw(function()
    got = rt:perform(Op.choice({ Op.always('skip'), p:signal_op() }))
  end):label('pulse-choice')
  assert_status(rt:run(), 'found')
  assert_eq(got, 'skip')
  local rt2 = new_runtime()
  local version
  rt2:spawn_raw(function() version = rt2:perform(p:version_op()) end):label('pulse-version')
  assert_status(rt2:run(), 'found')
  assert_eq(version, 0)
end

local function test_countdown_latch_wait_and_together_drain()
  local wg = CountdownLatch.new()
  local rt = new_runtime()
  local rows
  rt:spawn_raw(function()
    rows = rt:perform(Op.together({ wg:add_op(1), wg:done_op(), wg:wait_op() }))
  end):label('wg-together')
  assert_status(rt:run(), 'found')
  assert_eq(rows[1][1], true)
  assert_eq(rows[2][1], true)
  assert_eq(rows[3][1], true)
  assert_eq(rows[3][2], 1)
  assert_eq(wg.state.value.count, 0)
  assert_eq(wg.state.value.generation, 1)
end

local function test_countdown_latch_each_done_does_not_supply_wait()
  local wg = CountdownLatch.new({ count = 1, generation = 1 })
  local rt = new_runtime()
  local rows
  rt:spawn_raw(function()
    rows = rt:perform(Op.each({ wg:done_op(), wg:wait_op():or_else(Op.always('blocked')) }))
  end):label('wg-each')
  assert_status(rt:run(), 'found')
  assert_eq(rows[1][1], true)
  assert_eq(rows[2][1], 'blocked')
  assert_eq(wg.state.value.count, 0)
end

local function test_countdown_latch_negative_count_is_absent()
  local wg = CountdownLatch.new()
  local rt = new_runtime({ quiet_deadlock = true })
  rt:spawn_raw(function()
    rt:perform(wg:done_op())
  end):label('wg-negative')
  assert_not_found(rt:run(), 'negative countdown latch count should not commit')
  assert_eq(wg.state.value.count, 0)
end

local function test_mailbox_rendezvous_send_recv()
  local tx, rx = FibersMailbox.new()
  local rt = new_runtime()
  local sent, got
  rt:spawn_raw(function()
    sent = rt:perform(tx:send_op('hello'))
  end):label('mb-send')
  rt:spawn_raw(function()
    got = rt:perform(rx:recv_op())
  end):label('mb-recv')
  assert_status(rt:run(), 'found')
  assert_eq(sent, true)
  assert_eq(got, 'hello')
end

local function test_mailbox_buffered_fifo_close_and_drain()
  local tx, rx = FibersMailbox.new(2)
  local rt = new_runtime()
  rt:spawn_raw(function()
    rt:perform(Op.together({ tx:send_op('a'), tx:send_op('b'), tx:close_op('eof') }))
  end):label('mb-fill-close')
  assert_status(rt:run(), 'found')

  local rt2 = new_runtime()
  local a, b, c, why
  rt2:spawn_raw(function()
    a = rt2:perform(rx:recv_op())
    b = rt2:perform(rx:recv_op())
    c = rt2:perform(rx:recv_op())
    why = rt2:perform(rx:why_op())
  end):label('mb-drain')
  assert_status(rt2:run(), 'found')
  assert_eq(a, 'a')
  assert_eq(b, 'b')
  assert_eq(c, nil)
  assert_eq(why, 'eof')
end

local function test_mailbox_close_wakes_blocked_sender_and_receiver()
  local tx, rx = FibersMailbox.new()
  local rt = new_runtime({ quiet_deadlock = true })
  local send_done = false
  local send_result = 'unset'
  rt:spawn_raw(function()
    send_result = rt:perform(tx:send_op('x'))
    send_done = true
  end):label('mb-blocked-send')
  assert_status(rt:run(), 'quiescent')
  rt:spawn_raw(function()
    rt:perform(tx:close_op('bye'))
  end):label('mb-close')
  assert_status(rt:run(), 'found')
  assert_eq(send_done, true)
  assert_eq(send_result, nil)

  local tx2, rx2 = FibersMailbox.new()
  local rt2 = new_runtime({ quiet_deadlock = true })
  local recv_done = false
  local recv_result = 'unset'
  rt2:spawn_raw(function()
    recv_result = rt2:perform(rx2:recv_op())
    recv_done = true
  end):label('mb-blocked-recv')
  assert_status(rt2:run(), 'quiescent')
  rt2:spawn_raw(function()
    rt2:perform(tx2:close_op('bye'))
  end):label('mb-close2')
  assert_status(rt2:run(), 'found')
  assert_eq(recv_done, true)
  assert_eq(recv_result, nil)
end

local function test_mailbox_clone_and_last_sender_close()
  local tx, rx = FibersMailbox.new(1)
  local rt = new_runtime()
  local tx2
  rt:spawn_raw(function()
    tx2 = rt:perform(tx:clone_op())
    rt:perform(tx:close_op('first'))
    rt:perform(tx2:send_op('still-open'))
  end):label('mb-clone-and-first-close')
  rt:spawn_raw(function()
    assert_eq(rt:perform(rx:recv_op()), 'still-open')
  end):label('mb-recv-open')
  assert_status(rt:run(), 'found')

  local rt2 = new_runtime()
  local value, reason
  rt2:spawn_raw(function()
    rt2:perform(tx2:close_op('second'))
    value, reason = rt2:perform(rx:recv_op())
  end):label('mb-last-close')
  assert_status(rt2:run(), 'found')
  assert_eq(value, nil)
  assert_eq(reason, 'first')
end

local function test_mailbox_full_policies()
  local reject_tx = FibersMailbox.reject_newest(1)
  local rt = new_runtime()
  local ok1, ok2, why2, dropped
  rt:spawn_raw(function()
    ok1 = rt:perform(reject_tx:send_op('a'))
    ok2, why2 = rt:perform(reject_tx:send_op('b'))
    dropped = rt:perform(reject_tx:dropped_op())
  end):label('mb-reject')
  assert_status(rt:run(), 'found')
  assert_eq(ok1, true)
  assert_eq(ok2, false)
  assert_eq(why2, 'full')
  assert_eq(dropped, 1)

  local drop_tx, drop_rx = FibersMailbox.drop_oldest(1)
  local rt2 = new_runtime()
  local got, dropped2
  rt2:spawn_raw(function()
    rt2:perform(drop_tx:send_op('a'))
    rt2:perform(drop_tx:send_op('b'))
    got = rt2:perform(drop_rx:recv_op())
    dropped2 = rt2:perform(drop_tx:dropped_op())
  end):label('mb-drop-oldest')
  assert_status(rt2:run(), 'found')
  assert_eq(got, 'b')
  assert_eq(dropped2, 1)
end

local function test_mailbox_losing_send_branch_does_not_enqueue()
  local tx, rx = FibersMailbox.new(1)
  local rt = new_runtime({ choice_seed = 2 })
  local got
  rt:spawn_raw(function()
    got = rt:perform(Op.choice({ Op.always('skip'), tx:send_op('lost') }))
  end):label('mb-losing-send')
  assert_status(rt:run(), 'found')
  assert_eq(got, 'skip')

  local rt2 = new_runtime()
  local empty
  rt2:spawn_raw(function()
    empty = rt2:perform(rx:recv_op():or_else(Op.always('empty')))
  end):label('mb-empty-check')
  assert_status(rt2:run(), 'found')
  assert_eq(empty, 'empty')
end

local function test_pulse_signal_after_close_is_noop()
  local p = FibersPulse.new()
  local rt = new_runtime()
  rt:spawn_raw(function()
    rt:perform(p:close_op('done'))
  end):label('pulse-close')
  assert_status(rt:run(), 'found')
  local rt2 = new_runtime()
  local before, signalled, after
  rt2:spawn_raw(function()
    before = rt2:perform(p:version_op())
    signalled = rt2:perform(p:signal_op())
    after = rt2:perform(p:version_op())
  end):label('pulse-closed-signal')
  assert_status(rt2:run(), 'found')
  assert_eq(signalled, nil)
  assert_eq(before, 0)
  assert_eq(after, 0)
end

local function test_mailbox_stale_sender_close_cannot_set_reason()
  local tx, rx = FibersMailbox.new(1)
  local rt = new_runtime()
  rt:spawn_raw(function()
    rt:perform(tx:close_op())
    rt:perform(tx:close_op('late'))
  end):label('mb-stale-close')
  assert_status(rt:run(), 'found')

  local rt2 = new_runtime()
  local value, reason, why
  rt2:spawn_raw(function()
    value, reason = rt2:perform(rx:recv_op())
    why = rt2:perform(rx:why_op())
  end):label('mb-stale-close-check')
  assert_status(rt2:run(), 'found')
  assert_eq(value, nil)
  assert_eq(reason, nil)
  assert_eq(why, nil)
end

local function test_mailbox_reusable_clone_op_makes_distinct_senders()
  local tx, rx = FibersMailbox.new(1)
  local clone = tx:clone_op()
  local tx2, tx3
  local rt = new_runtime()
  rt:spawn_raw(function()
    tx2 = rt:perform(clone)
    tx3 = rt:perform(clone)
    rt:perform(tx2:close_op())
    rt:perform(tx3:send_op('third'))
  end):label('mb-reusable-clone')
  rt:spawn_raw(function()
    assert_eq(rt:perform(rx:recv_op()), 'third')
  end):label('mb-reusable-clone-recv')
  assert_status(rt:run(), 'found')

  local rt2 = new_runtime()
  local final
  rt2:spawn_raw(function()
    rt2:perform(tx3:close_op())
    rt2:perform(tx:send_op('first'))
    final = rt2:perform(rx:recv_op())
    rt2:perform(tx:close_op())
  end):label('mb-distinct-closes')
  assert_status(rt2:run(), 'found')
  assert_eq(final, 'first')
end

local function test_channel_facade()
  local rv = FibersChannel.new(0)
  local rt = new_runtime()
  local sent, got
  rt:spawn_raw(function()
    sent = rt:perform(rv:put_op('rv'))
  end):label('ch-rv-put')
  rt:spawn_raw(function()
    got = rt:perform(rv:get_op())
  end):label('ch-rv-get')
  assert_status(rt:run(), 'found')
  assert_eq(sent, true)
  assert_eq(got, 'rv')

  local q = FibersChannel.new(2)
  local rt2 = new_runtime()
  local a, b
  rt2:spawn_raw(function()
    rt2:perform(q:put_op('a'))
    rt2:perform(q:put_op('b'))
    a = rt2:perform(q:get_op())
    b = rt2:perform(q:get_op())
  end):label('ch-queue')
  assert_status(rt2:run(), 'found')
  assert_eq(a, 'a')
  assert_eq(b, 'b')
end

local tests = {
  test_top_level_exports,
  test_pulse_signal_and_changed,
  test_pulse_waits_and_close_wakes,
  test_pulse_losing_signal_branch_does_not_mutate,
  test_pulse_signal_after_close_is_noop,
  test_countdown_latch_wait_and_together_drain,
  test_countdown_latch_each_done_does_not_supply_wait,
  test_countdown_latch_negative_count_is_absent,
  test_mailbox_rendezvous_send_recv,
  test_mailbox_buffered_fifo_close_and_drain,
  test_mailbox_close_wakes_blocked_sender_and_receiver,
  test_mailbox_clone_and_last_sender_close,
  test_mailbox_full_policies,
  test_mailbox_losing_send_branch_does_not_enqueue,
  test_mailbox_stale_sender_close_cannot_set_reason,
  test_mailbox_reusable_clone_op_makes_distinct_senders,
  test_channel_facade,
}

for i = 1, #tests do
  tests[i]()
end

print('examples/recipes/tests/test_messaging_and_countdown.lua: ok')

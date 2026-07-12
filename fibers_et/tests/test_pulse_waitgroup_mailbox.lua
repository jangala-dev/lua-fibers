-- Pulse, WaitGroup and Mailbox compound facilities over base atomics.

package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

local fibers = require('fibers')
local Op = require('fibers.atoms.op')
local Runtime = require('fibers.kernel.runtime')

local function fail(msg) error(msg, 2) end
local function assert_eq(actual, expected, msg)
  if actual ~= expected then fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual)) end
end
local function assert_status(status, tag, msg)
  if not status or status.tag ~= tag then fail((msg or 'status mismatch') .. ': expected ' .. tostring(tag) .. ', got ' .. tostring(status and status.tag)) end
end
local function assert_not_found(status, msg)
  if status and status.tag == 'found' then fail(msg or 'operation unexpectedly committed') end
end
local function new_runtime(opts) return Runtime.new(opts or {}) end

local function test_top_level_exports()
  assert_eq(type(fibers.Pulse.new), 'function', 'Pulse export')
  assert_eq(type(fibers.WaitGroup.new), 'function', 'WaitGroup export')
  assert_eq(type(fibers.Mailbox.new), 'function', 'Mailbox export')
  assert_eq(type(fibers.Channel.new), 'function', 'Channel export')
end

local function test_pulse_signal_and_changed()
  local p = fibers.Pulse.new()
  local rt = new_runtime()
  local version
  rt:spawn_raw(function() version = rt:perform(p:signal_op()) end, 'pulse-signal')
  assert_status(rt:run(), 'found')
  assert_eq(version, 1)
  assert_eq(p.state.value.version, 1)

  local rt2 = new_runtime()
  local seen, reason
  rt2:spawn_raw(function() seen, reason = rt2:perform(p:changed_op(0)) end, 'pulse-changed')
  assert_status(rt2:run(), 'found')
  assert_eq(seen, 1)
  assert_eq(reason, nil)
end

local function test_pulse_waits_and_close_wakes()
  local p = fibers.Pulse.new()
  local rt = new_runtime({ quiet_deadlock = true })
  local done = false
  local version, reason
  rt:spawn_raw(function() version, reason = rt:perform(p:changed_op(0)); done = true end, 'pulse-waiter')
  assert_status(rt:run(), 'quiescent')
  assert_eq(done, false)
  rt:spawn_raw(function() rt:perform(p:close_op('shutdown')) end, 'pulse-close')
  assert_status(rt:run(), 'found')
  assert_eq(done, true)
  assert_eq(version, nil)
  assert_eq(reason, 'shutdown')
end

local function test_pulse_losing_signal_branch_does_not_mutate()
  local p = fibers.Pulse.new()
  local rt = new_runtime({ choice_seed = 2 })
  local got
  rt:spawn_raw(function()
    got = rt:perform(Op.choice({ Op.always('skip'), p:signal_op() }))
  end, 'pulse-choice')
  assert_status(rt:run(), 'found')
  assert_eq(got, 'skip')
  assert_eq(p.state.value.version, 0)
end

local function test_waitgroup_wait_and_tensor_drain()
  local wg = fibers.WaitGroup.new()
  local rt = new_runtime()
  local rows
  rt:spawn_raw(function()
    rows = rt:perform(Op.tensor({ wg:add_op(1), wg:done_op(), wg:wait_op() }))
  end, 'wg-tensor')
  assert_status(rt:run(), 'found')
  assert_eq(rows[1][1], true)
  assert_eq(rows[2][1], true)
  assert_eq(rows[3][1], true)
  assert_eq(rows[3][2], 1)
  assert_eq(wg.state.value.count, 0)
  assert_eq(wg.state.value.generation, 1)
end

local function test_waitgroup_all_done_does_not_supply_wait()
  local wg = fibers.WaitGroup.new({ count = 1, generation = 1 })
  local rt = new_runtime()
  local rows
  rt:spawn_raw(function()
    rows = rt:perform(Op.all({ wg:done_op(), wg:wait_op():or_else(Op.always('blocked')) }))
  end, 'wg-all')
  assert_status(rt:run(), 'found')
  assert_eq(rows[1][1], true)
  assert_eq(rows[2][1], 'blocked')
  assert_eq(wg.state.value.count, 0)
end

local function test_waitgroup_negative_count_is_absent()
  local wg = fibers.WaitGroup.new()
  local rt = new_runtime({ quiet_deadlock = true })
  rt:spawn_raw(function() rt:perform(wg:done_op()) end, 'wg-negative')
  assert_not_found(rt:run(), 'negative waitgroup count should not commit')
  assert_eq(wg.state.value.count, 0)
end

local function test_mailbox_rendezvous_send_recv()
  local tx, rx = fibers.Mailbox.new()
  local rt = new_runtime()
  local sent, got
  rt:spawn_raw(function() sent = rt:perform(tx:send_op('hello')) end, 'mb-send')
  rt:spawn_raw(function() got = rt:perform(rx:recv_op()) end, 'mb-recv')
  assert_status(rt:run(), 'found')
  assert_eq(sent, true)
  assert_eq(got, 'hello')
end

local function test_mailbox_buffered_fifo_close_and_drain()
  local tx, rx = fibers.Mailbox.new(2)
  local rt = new_runtime()
  rt:spawn_raw(function()
    rt:perform(Op.tensor({ tx:send_op('a'), tx:send_op('b'), tx:close_op('eof') }))
  end, 'mb-fill-close')
  assert_status(rt:run(), 'found')

  local rt2 = new_runtime()
  local a, b, c, why
  rt2:spawn_raw(function()
    a = rt2:perform(rx:recv_op())
    b = rt2:perform(rx:recv_op())
    c = rt2:perform(rx:recv_op())
    why = rt2:perform(rx:why_op())
  end, 'mb-drain')
  assert_status(rt2:run(), 'found')
  assert_eq(a, 'a')
  assert_eq(b, 'b')
  assert_eq(c, nil)
  assert_eq(why, 'eof')
end

local function test_mailbox_close_wakes_blocked_sender_and_receiver()
  local tx, rx = fibers.Mailbox.new()
  local rt = new_runtime({ quiet_deadlock = true })
  local send_done = false
  local send_result = 'unset'
  rt:spawn_raw(function() send_result = rt:perform(tx:send_op('x')); send_done = true end, 'mb-blocked-send')
  assert_status(rt:run(), 'quiescent')
  rt:spawn_raw(function() rt:perform(tx:close_op('bye')) end, 'mb-close')
  assert_status(rt:run(), 'found')
  assert_eq(send_done, true)
  assert_eq(send_result, nil)

  local tx2, rx2 = fibers.Mailbox.new()
  local rt2 = new_runtime({ quiet_deadlock = true })
  local recv_done = false
  local recv_result = 'unset'
  rt2:spawn_raw(function() recv_result = rt2:perform(rx2:recv_op()); recv_done = true end, 'mb-blocked-recv')
  assert_status(rt2:run(), 'quiescent')
  rt2:spawn_raw(function() rt2:perform(tx2:close_op('bye')) end, 'mb-close2')
  assert_status(rt2:run(), 'found')
  assert_eq(recv_done, true)
  assert_eq(recv_result, nil)
end

local function test_mailbox_clone_and_last_sender_close()
  local tx, rx = fibers.Mailbox.new(1)
  local rt = new_runtime()
  local tx2
  rt:spawn_raw(function() tx2 = rt:perform(tx:clone_op()) end, 'mb-clone')
  assert_status(rt:run(), 'found')

  local rt2 = new_runtime()
  local after_first_close, after_second_close
  rt2:spawn_raw(function()
    rt2:perform(tx:close_op('first'))
    after_first_close = rt2:perform(rx:snapshot_op())
    rt2:perform(tx2:close_op('second'))
    after_second_close = rt2:perform(rx:snapshot_op())
  end, 'mb-close-senders')
  assert_status(rt2:run(), 'found')
  assert_eq(after_first_close.closed, false)
  assert_eq(after_first_close.sender_count, 1)
  assert_eq(after_second_close.closed, true)
  assert_eq(after_second_close.reason, 'first')
end

local function test_mailbox_full_policies()
  local reject_tx = fibers.Mailbox.new(1, { full = 'reject_newest' })
  local rt = new_runtime()
  local ok1, ok2, why2, dropped
  rt:spawn_raw(function()
    ok1 = rt:perform(reject_tx:send_op('a'))
    ok2, why2 = rt:perform(reject_tx:send_op('b'))
    dropped = rt:perform(reject_tx:dropped_op())
  end, 'mb-reject')
  assert_status(rt:run(), 'found')
  assert_eq(ok1, true)
  assert_eq(ok2, false)
  assert_eq(why2, 'full')
  assert_eq(dropped, 1)

  local drop_tx, drop_rx = fibers.Mailbox.new(1, { full = 'drop_oldest' })
  local rt2 = new_runtime()
  local got, dropped2
  rt2:spawn_raw(function()
    rt2:perform(drop_tx:send_op('a'))
    rt2:perform(drop_tx:send_op('b'))
    got = rt2:perform(drop_rx:recv_op())
    dropped2 = rt2:perform(drop_tx:dropped_op())
  end, 'mb-drop-oldest')
  assert_status(rt2:run(), 'found')
  assert_eq(got, 'b')
  assert_eq(dropped2, 1)
end

local function test_mailbox_losing_send_branch_does_not_enqueue()
  local tx, rx = fibers.Mailbox.new(1)
  local rt = new_runtime({ choice_seed = 2 })
  local got
  rt:spawn_raw(function()
    got = rt:perform(Op.choice({ Op.always('skip'), tx:send_op('lost') }))
  end, 'mb-losing-send')
  assert_status(rt:run(), 'found')
  assert_eq(got, 'skip')

  local rt2 = new_runtime()
  local snap
  rt2:spawn_raw(function() snap = rt2:perform(rx:snapshot_op()) end, 'mb-snapshot')
  assert_status(rt2:run(), 'found')
  assert_eq(#snap.items, 0)
end


local function test_pulse_signal_after_close_is_noop()
  local p = fibers.Pulse.new()
  local rt = new_runtime()
  rt:spawn_raw(function() rt:perform(p:close_op('done')) end, 'pulse-close')
  assert_status(rt:run(), 'found')
  local scalar_version = p.state.version

  local rt2 = new_runtime()
  local v
  rt2:spawn_raw(function() v = rt2:perform(p:signal_op()) end, 'pulse-closed-signal')
  assert_status(rt2:run(), 'found')
  assert_eq(v, nil)
  assert_eq(p.state.value.version, 0)
  assert_eq(p.state.version, scalar_version)
end

local function test_mailbox_stale_sender_close_cannot_set_reason()
  local tx, rx = fibers.Mailbox.new(1)
  local rt = new_runtime()
  rt:spawn_raw(function()
    rt:perform(tx:close_op())
    rt:perform(tx:close_op('late'))
  end, 'mb-stale-close')
  assert_status(rt:run(), 'found')

  local rt2 = new_runtime()
  local snap
  rt2:spawn_raw(function() snap = rt2:perform(rx:snapshot_op()) end, 'mb-stale-snapshot')
  assert_status(rt2:run(), 'found')
  assert_eq(snap.closed, true)
  assert_eq(snap.reason, nil)
end

local function test_mailbox_reusable_clone_op_makes_distinct_senders()
  local tx, rx = fibers.Mailbox.new(1)
  local clone = tx:clone_op()
  local tx2, tx3, snap
  local rt = new_runtime()
  rt:spawn_raw(function()
    tx2 = rt:perform(clone)
    tx3 = rt:perform(clone)
    snap = rt:perform(rx:snapshot_op())
  end, 'mb-reusable-clone')
  assert_status(rt:run(), 'found')
  assert_eq(type(tx2.send_op), 'function')
  assert_eq(type(tx3.send_op), 'function')
  assert_eq(snap.sender_count, 3)
  assert_eq(snap.next_sender_seq, 3)

  local rt2 = new_runtime()
  local after_one, after_two
  rt2:spawn_raw(function()
    rt2:perform(tx2:close_op())
    after_one = rt2:perform(rx:snapshot_op())
    rt2:perform(tx3:close_op())
    after_two = rt2:perform(rx:snapshot_op())
  end, 'mb-distinct-closes')
  assert_status(rt2:run(), 'found')
  assert_eq(after_one.sender_count, 2)
  assert_eq(after_two.sender_count, 1)
  assert_eq(after_two.closed, false)
end

local function test_channel_facade()
  local rv = fibers.Channel.new(0)
  local rt = new_runtime()
  local sent, got
  rt:spawn_raw(function() sent = rt:perform(rv:put_op('rv')) end, 'ch-rv-put')
  rt:spawn_raw(function() got = rt:perform(rv:get_op()) end, 'ch-rv-get')
  assert_status(rt:run(), 'found')
  assert_eq(sent, true)
  assert_eq(got, 'rv')

  local q = fibers.Channel.new(2)
  local rt2 = new_runtime()
  local a, b
  rt2:spawn_raw(function()
    rt2:perform(q:put_op('a'))
    rt2:perform(q:put_op('b'))
    a = rt2:perform(q:get_op())
    b = rt2:perform(q:get_op())
  end, 'ch-queue')
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
  test_waitgroup_wait_and_tensor_drain,
  test_waitgroup_all_done_does_not_supply_wait,
  test_waitgroup_negative_count_is_absent,
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

for i = 1, #tests do tests[i]() end

print('tests/test_pulse_waitgroup_mailbox.lua: ok')

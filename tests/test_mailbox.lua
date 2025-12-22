print('testing: fibers.mailbox')

package.path = '../src/?.lua;' .. package.path

local fibers  = require 'fibers'
local mailbox = require 'fibers.mailbox'
local sleep   = require 'fibers.sleep'
local op      = require 'fibers.op'
local wg_mod  = require 'fibers.waitgroup'

----------------------------------------------------------------------
-- helpers
----------------------------------------------------------------------

local function assert_eq(a, b, msg)
	if a ~= b then
		error((msg or 'assert_eq failed') .. (': expected ' .. tostring(b) .. ', got ' .. tostring(a)), 2)
	end
end

local function assert_truthy(v, msg)
	if not v then
		error(msg or 'assert_truthy failed', 2)
	end
end

local function assert_falsy(v, msg)
	if v then
		error(msg or 'assert_falsy failed', 2)
	end
end

local function collect_iter(rx)
	local out = {}
	for v in rx:iter() do
		out[#out + 1] = v
	end
	return out
end

----------------------------------------------------------------------
-- tests
----------------------------------------------------------------------

local function test_rendezvous_basic()
	local tx, rx = mailbox.new(0)

	local wg = wg_mod.new()
	wg:add(2)

	local got = {}

	fibers.spawn(function ()
		-- receiver: read one, then see end
		got[1] = rx:recv()
		got[2] = rx:recv()
		wg:done()
	end)

	fibers.spawn(function ()
		sleep.sleep(0.02) -- ensure receiver blocks first
		local ok = tx:send('hello')
		assert_eq(ok, true, 'send should succeed')
		tx:close('done')
		wg:done()
	end)

	wg:wait()

	assert_eq(got[1], 'hello', 'receiver should get message')
	assert_eq(got[2], nil, 'receiver should see end after close+drain')
	assert_eq(rx:why(), 'done', 'receiver should see close reason')
end

local function test_buffered_fifo_order_and_drain()
	local tx, rx = mailbox.new(4)

	local ok1 = tx:send(1)
	local ok2 = tx:send(2)
	local ok3 = tx:send(3)
	assert_eq(ok1, true)
	assert_eq(ok2, true)
	assert_eq(ok3, true)

	tx:close('finished')

	local xs = collect_iter(rx)
	assert_eq(#xs, 3)
	assert_eq(xs[1], 1)
	assert_eq(xs[2], 2)
	assert_eq(xs[3], 3)

	assert_eq(rx:why(), 'finished')
end

local function test_send_after_close_is_rejected()
	local tx, rx = mailbox.new(0)

	tx:close('no more')

	local ok = tx:send('x')
	assert_eq(ok, nil, 'send after close should be rejected')

	local v = rx:recv()
	assert_eq(v, nil, 'recv on closed+empty should return nil')
	assert_eq(rx:why(), 'no more')
end

local function test_nil_payload_is_error()
	local tx, rx = mailbox.new(0)

	local ok, err = pcall(function ()
		tx:send(nil)
	end)

	assert_falsy(ok, 'sending nil should error')
	assert_truthy(err ~= nil, 'expected an error object/message')

	-- close so receiver is not left blocking if someone uses it later
	tx:close('end')
	assert_eq(rx:recv(), nil)
end

local function test_multi_producer_clone_and_reason_first_non_nil_wins()
	local tx, rx = mailbox.new(8)
	local tx2 = tx:clone()

	local wg = wg_mod.new()
	wg:add(2)

	fibers.spawn(function ()
		for i = 1, 3 do
			assert_eq(tx:send('a' .. i), true)
		end
		-- close with a reason first
		tx:close('r1')
		wg:done()
	end)

	fibers.spawn(function ()
		for i = 1, 2 do
			assert_eq(tx2:send('b' .. i), true)
		end
		-- later close with another reason; should not override
		sleep.sleep(0.02)
		tx2:close('r2')
		wg:done()
	end)

	wg:wait()

	local got = collect_iter(rx)
	assert_eq(#got, 5)
	-- Do not assert interleaving between producers, but do assert membership.
	local seen = {}
	for _, v in ipairs(got) do seen[v] = (seen[v] or 0) + 1 end
	assert_eq(seen['a1'], 1)
	assert_eq(seen['a2'], 1)
	assert_eq(seen['a3'], 1)
	assert_eq(seen['b1'], 1)
	assert_eq(seen['b2'], 1)

	assert_eq(rx:why(), 'r1', 'first non-nil close reason should win')
end

local function test_choice_timeout_then_message()
	local tx, rx = mailbox.new(0)

	-- First, no message available: should timeout.
	local tag = fibers.perform(
		op.choice(
			rx:recv_op():wrap(function (v) return 'msg', v end),
			sleep.sleep_op(0.03):wrap(function () return 'timeout' end)
		)
	)
	assert_eq(tag, 'timeout', 'expected timeout when mailbox empty')

	-- Now arrange a message, then race again.
	local wg = wg_mod.new()
	wg:add(1)
	fibers.spawn(function ()
		sleep.sleep(0.01)
		tx:send('ok')
		tx:close('done')
		wg:done()
	end)

	local tag2, v2 = fibers.perform(
		op.choice(
			rx:recv_op():wrap(function (v) return 'msg', v end),
			sleep.sleep_op(0.20):wrap(function () return 'timeout', nil end)
		)
	)
	assert_eq(tag2, 'msg')
	assert_eq(v2, 'ok')

	-- Drain end-of-stream.
	assert_eq(rx:recv(), nil)
	assert_eq(rx:why(), 'done')
	wg:wait()
end

local function test_choice_cancels_blocked_send_and_does_not_deliver()
	local tx, rx = mailbox.new(0)

	-- Start a choice that would block on send, but we time it out.
	local tag = fibers.perform(
		op.choice(
			tx:send_op('BAD'):wrap(function (ok) return 'sent', ok end),
			sleep.sleep_op(0.03):wrap(function () return 'timeout' end)
		)
	)
	assert_eq(tag, 'timeout')

	-- Now send a real message with a receiver; must not receive 'BAD'.
	local wg = wg_mod.new()
	wg:add(2)

	local got

	fibers.spawn(function ()
		got = rx:recv()
		wg:done()
	end)

	fibers.spawn(function ()
		sleep.sleep(0.02)
		assert_eq(tx:send('GOOD'), true)
		tx:close('end')
		wg:done()
	end)

	wg:wait()

	assert_eq(got, 'GOOD', 'cancelled send must not be delivered later')
	assert_eq(rx:recv(), nil)
end

local function test_close_wakes_blocked_receiver()
	local tx, rx = mailbox.new(0)

	local wg = wg_mod.new()
	wg:add(1)

	local got

	fibers.spawn(function ()
		got = rx:recv() -- should block until close
		wg:done()
	end)

	sleep.sleep(0.02)
	tx:close('closed without messages')

	wg:wait()

	assert_eq(got, nil, 'blocked receiver should wake and see end-of-stream')
	assert_eq(rx:why(), 'closed without messages')
end

local function test_close_wakes_blocked_sender()
	local tx, rx = mailbox.new(0)
	local tx2 = tx:clone()

	local wg = wg_mod.new()
	wg:add(1)

	local send_ok

	fibers.spawn(function ()
		-- No receiver: this blocks until mailbox closes.
		send_ok = tx2:send('will-not-deliver')
		wg:done()
	end)

	-- Ensure sender is blocked.
	sleep.sleep(0.03)

	-- Closing both handles causes mailbox closure; blocked send should return nil.
	tx:close('shutdown')
	tx2:close('shutdown')

	wg:wait()

	assert_eq(send_ok, nil, 'blocked send should be rejected when mailbox closes')
	assert_eq(rx:recv(), nil, 'receiver should see end-of-stream')
	assert_eq(rx:why(), 'shutdown')
end

local function test_clone_after_close_is_inert()
	local tx, rx = mailbox.new(0)
	tx:close('done')

	local tx2 = tx:clone()
	assert_eq(tx2:send('x'), nil, 'clone after close should not send')
	assert_eq(rx:recv(), nil)
	assert_eq(rx:why(), 'done')
end

----------------------------------------------------------------------
-- main
----------------------------------------------------------------------

local function main()
	test_rendezvous_basic()
	test_buffered_fifo_order_and_drain()
	test_send_after_close_is_rejected()
	test_nil_payload_is_error()
	test_multi_producer_clone_and_reason_first_non_nil_wins()
	test_choice_timeout_then_message()
	test_choice_cancels_blocked_send_and_does_not_deliver()
	test_close_wakes_blocked_receiver()
	test_close_wakes_blocked_sender()
	test_clone_after_close_is_inert()

	print('All mailbox tests passed!')
end

fibers.run(main)

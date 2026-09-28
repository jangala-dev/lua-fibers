-- tests/tricky_cases.lua
--
-- Exercises tricky cases in the op/scope runtime using sleep + channel.
-- Intended to run as a plain Lua script:
--   lua tests/tricky_cases.lua
--

--- Tests the Timer implementation.
print('test: tricky')

-- look one level up
package.path = '../src/?.lua;' .. package.path


local fibers  = require 'fibers'
local op      = require 'fibers.op'
local sleep   = require 'fibers.sleep'
local channel = require 'fibers.channel'

----------------------------------------------------------------------
-- Minimal assertions / harness
----------------------------------------------------------------------

local function fail(msg)
	error(msg or 'test failed', 0)
end

local function assert_true(v, msg)
	if not v then fail(msg or 'expected true') end
end

local function assert_eq(a, b, msg)
	if a ~= b then
		fail((msg or 'unexpected value') .. (': got ' .. tostring(a) .. ', want ' .. tostring(b)))
	end
end

local function assert_contains(hay, needle, msg)
	hay = tostring(hay)
	if not hay:find(needle, 1, true) then
		fail((msg or 'expected substring') .. (': "' .. needle .. '" not in "' .. hay .. '"'))
	end
end

local tests = {}
local function test(name, fn)
	tests[#tests + 1] = { name = name, fn = fn }
end

----------------------------------------------------------------------
-- Tests
----------------------------------------------------------------------

-- 1) Late completion should be harmless (losing completion task fires later).
test('choice: late completion of losing timer does not crash', function (_)
	local ev = op.choice(
		sleep.sleep_op(0.02):wrap(function () return 'fast' end),
		sleep.sleep_op(0.08):wrap(function () return 'slow' end)
	)

	local v = fibers.perform(ev)
	assert_eq(v, 'fast', 'expected fast arm to win')

	-- Allow the losing arm’s scheduled completion task to run later.
	sleep.sleep(0.12)
end)

-- 2) Abort handler should run exactly once for the losing arm.
test('choice: abort handler runs once', function (_)
	local abort_count = 0

	local ev = op.choice(
		sleep.sleep_op(0.02):wrap(function () return 'win' end),
		sleep.sleep_op(0.08)
			:on_abort(function () abort_count = abort_count + 1 end)
			:wrap(function () return 'lose' end)
	)

	local v = fibers.perform(ev)
	assert_eq(v, 'win', 'expected winning arm')

	sleep.sleep(0.12)
	assert_eq(abort_count, 1, 'expected abort handler to run once')

	-- Ensure it does not run again later.
	sleep.sleep(0.10)
	assert_eq(abort_count, 1, 'abort handler ran more than once')
end)

-- 3) with_nack: losing arm’s nack becomes ready; winner’s nack does not.
test('with_nack: loser nack fires, winner nack does not', function (_)
	local c1     = channel.new()      -- rendezvous channel for arm1
	local c2     = channel.new()      -- rendezvous channel for arm2 (never signalled)
	local events = channel.new(10)    -- buffered: reports nack firings
	local stop   = channel.new(10)    -- buffered: stops observers

	local function arm(label, ch)
		return op.with_nack(function (nack_op)
			-- Observer fibre waits for either nack or stop.
			fibers.spawn(function ()
				local which = fibers.perform(op.choice(
					nack_op:wrap(function () return 'nack' end),
					stop:get_op():wrap(function () return 'stop' end)
				))

				if which == 'nack' then
					events:put(label)
				end
			end)

			-- Main arm blocks on channel receive.
			return ch:get_op():wrap(function (v) return label, v end)
		end)
	end

	-- Arrange arm1 to win later (ensures we take the blocking choice path).
	fibers.spawn(function ()
		sleep.sleep(0.02)
		c1:put('msg1')
	end)

	local winner, payload = fibers.perform(op.choice(
		arm('arm1', c1),
		arm('arm2', c2)
	))

	assert_eq(winner, 'arm1', 'expected arm1 to win')
	assert_eq(payload, 'msg1', 'expected arm1 payload')

	-- Give nack signalling time to propagate.
	sleep.sleep(0.02)

	-- Stop both observers (winner’s observer should exit via stop, not nack).
	stop:put(true)
	stop:put(true)

	sleep.sleep(0.02)

	-- Drain events non-blockingly.
	local e1 = fibers.perform(events:get_op():or_else(function () return nil end))
	local e2 = fibers.perform(events:get_op():or_else(function () return nil end))

	assert_eq(e1, 'arm2', 'expected loser nack to fire for arm2')
	assert_true(e2 == nil, 'unexpected extra nack event: ' .. tostring(e2))
end)

-- 4) bracket/finally: release/cleanup happens once, with correct aborted flag.
test('bracket: release(true) on abort, release(false) on success', function (_)
	-- Abort case.
	do
		local calls = {}

		local function acquire() return {} end
		local function release(_, aborted)
			calls[#calls + 1] = aborted
		end
		local function use(_)
			return sleep.sleep_op(0.08)
		end

		local bracketed = op.bracket(acquire, release, use):wrap(function () return 'bracket' end)

		local v = fibers.perform(op.choice(
			sleep.sleep_op(0.02):wrap(function () return 'fast' end),
			bracketed
		))

		assert_eq(v, 'fast', 'expected non-bracket arm to win')

		sleep.sleep(0.12)
		assert_eq(#calls, 1, 'release should be called once (abort case)')
		assert_eq(calls[1], true, 'release should be called with aborted=true (abort case)')
	end

	-- Success case.
	do
		local calls = {}

		local function acquire() return {} end
		local function release(_, aborted)
			calls[#calls + 1] = aborted
		end
		local function use(_)
			return sleep.sleep_op(0.02)
		end

		local bracketed = op.bracket(acquire, release, use):wrap(function () return 'bracket' end)

		local v = fibers.perform(op.choice(
			bracketed,
			sleep.sleep_op(0.10):wrap(function () return 'slow' end)
		))

		assert_eq(v, 'bracket', 'expected bracket arm to win')

		sleep.sleep(0.06)
		assert_eq(#calls, 1, 'release should be called once (success case)')
		assert_eq(calls[1], false, 'release should be called with aborted=false (success case)')
	end
end)

-- 5) Scope fail-fast: first fault cancels siblings; cancelled sibling observes cancellation.
test('scope: fail-fast cancels siblings', function (_)
	-- Run the scenario in a nested scope boundary, and assert on its outcome.
	local st, _, primary = fibers.run_scope(function (s2)
		local events = channel.new(10)

		local ok1, err1 = s2:spawn(function ()
			sleep.sleep(0.02)
			error('boom', 0)
		end)
		assert_true(ok1, 'spawn child1 failed: ' .. tostring(err1))

		local ok2, err2 = s2:spawn(function ()
			-- This should be interrupted by scope cancellation (status-first).
			local cst, reason = fibers.try_perform(sleep.sleep_op(10))

			-- Report out using raw op.perform_raw so cancellation does not prevent reporting.
			op.perform_raw(events:put_op({ cst, reason }))
		end)
		assert_true(ok2, 'spawn child2 failed: ' .. tostring(err2))

		-- Wait for the sibling’s cancellation report without being interrupted by cancellation.
		local msg = op.perform_raw(events:get_op())
		assert_eq(msg[1], 'cancelled', 'expected sibling to observe cancellation')
		assert_contains(msg[2], 'boom', 'expected cancellation reason to include primary failure')
	end)

	assert_eq(st, 'failed', 'expected nested scope to fail')
	assert_contains(primary, 'boom', 'expected primary failure to include "boom"')
end)

-- 6) Late completion via channel rendezvous: losing receiver is queued then later matched.
test('choice: late completion of losing channel receive does not crash', function (_)
	local c    = channel.new()
	local done = channel.new(1) -- buffered so the reporter can't block

	local fast    = sleep.sleep_op(0.02):wrap(function () return 'fast' end)
	local slow_get = c:get_op():wrap(function (v) return 'got', v end)

	-- Run the choice: slow_get will enqueue then lose.
	local v = fibers.perform(op.choice(fast, slow_get))
	assert_eq(v, 'fast', 'expected timer arm to win')

	-- After the winner, attempt a send. This will call put_op.try(),
	-- which will scan/drop stale getq entries; but it must not block.
	fibers.spawn(function ()
		sleep.sleep(0.06)
		local r = fibers.perform(
			c:put_op('late'):or_else(function () return 'would_block' end)
		)
		done:put(r)
	end)

	local r = done:get()
	assert_eq(r, 'would_block', 'expected late send to be non-blocking and report would_block')

	-- Allow any queued tasks to run.
	sleep.sleep(0.05)
end)

-- 7) Stress pop_active / cleanup: many losing waiters then many late senders.
test('channel: stale queue entries are skipped under load', function (_)
	local c = channel.new() -- unbuffered
	local n_stale = 200
	local m = 50

	-- Create many stale receiver entries by having get_op lose to a fast timer.
	for _ = 1, n_stale do
		local fast = sleep.sleep_op(0.001):wrap(function () return true end)
		local lose = c:get_op():wrap(function () return false end)
		local ok = fibers.perform(op.choice(fast, lose))
		assert_eq(ok, true, 'expected fast arm to win')
	end

	local events = channel.new(m) -- buffered so receiver can report without blocking
	local ack    = channel.new()  -- unbuffered rendezvous for pacing

	-- Receiver: take m values, report them, ack each one.
	fibers.spawn(function ()
		for _ = 1, m do
			local v = c:get()
			events:put(v)
			ack:put(true)
		end
	end)

	-- Sender: send 1..m, waiting for ack each time.
	fibers.spawn(function ()
		for i = 1, m do
			c:put(i)
			ack:get()
		end
	end)

	-- Verify we actually received the sequence.
	for i = 1, m do
		local v = events:get()
		assert_eq(v, i, 'unexpected value received after stale-queue stress')
	end
end)


----------------------------------------------------------------------
-- Runner (single fibres.run invocation)
----------------------------------------------------------------------

local function run_all()
	local passed, failed = 0, 0
	local failures = {}

	for i = 1, #tests do
		local t = tests[i]

		-- Each test runs in its own child scope boundary so one failure does not stop the rest.
		local st, _, primary = fibers.run_scope(function (s)
			t.fn(s)
		end)

		if st == 'ok' then
			passed = passed + 1
			io.stdout:write(('ok   %s\n'):format(t.name))
		else
			failed = failed + 1
			local msg = tostring(primary or 'unknown failure')
			failures[#failures + 1] = ('not ok %s: %s'):format(t.name, msg)
			io.stdout:write(('not ok %s\n'):format(t.name))
		end
	end

	io.stdout:write(('\n%d passed, %d failed\n'):format(passed, failed))

	if failed > 0 then
		io.stdout:write(table.concat(failures, '\n') .. '\n')
		error(('test failures: %d'):format(failed), 0)
	end
end

-- Keep everything under a single scheduler lifetime.
fibers.run(function (_)
	-- Optional: reduce non-determinism if you have tests that depend on probe order.
	math.randomseed(1)

	run_all()
end)

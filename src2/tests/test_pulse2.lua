-- tests/test_pulse2.lua
package.path = '../?.lua;' .. package.path

local sched = require 'fibers.sched2'
local pulse = require 'fibers.pulse2'

local function assert_eq(a, b, msg)
	if a ~= b then
		error((msg or 'assert_eq failed') .. (': got ' .. tostring(a) .. ', want ' .. tostring(b)), 2)
	end
end

local function assert_true(x, msg)
	if not x then error(msg or 'assert_true failed', 2) end
end

local s = sched.new()

----------------------------------------------------------------------
-- Mock fibre task
----------------------------------------------------------------------

local function new_fiber(name)
	return {
		name = name or '<fib>',
		_queued = false,
		ran = 0,
		run = function(self) self.ran = self.ran + 1 end,
	}
end

----------------------------------------------------------------------
-- Mock wait token (implements the protocol Pulse expects)
-- - Tracks handles (pulse, idx, epoch)
-- - Supports de-dupe (_subscribed_to)
-- - Supports swap-with-tail update (_moved)
-- - On wake, cancels remaining handles and schedules its fibre (epoch-checked)
----------------------------------------------------------------------

local function new_token(fib)
	local tok = {
		fib = fib,
		expected_epoch = 0,

		-- Triples: [pulse, idx, epoch] per handle.
		handles = {},
		nh = 0,

		woke = 0,
		last_wake_epoch = nil,

		moved = 0,
		last_moved = nil, -- { pulse=..., old=..., new=..., epoch=... }
	}

	function tok:_begin_wait(epoch)
		self.expected_epoch = epoch
		self.nh = 0
		self.woke = 0
		self.last_wake_epoch = nil
		-- keep moved counters for later assertions
	end

	function tok:_subscribed_to(p, epoch)
		local hs = self.handles
		for i = 1, self.nh do
			local j = (i - 1) * 3 + 1
			if hs[j] == p and hs[j + 2] == epoch then
				return true
			end
		end
		return false
	end

	function tok:_add_handle(p, idx, epoch)
		local n = self.nh + 1
		self.nh = n
		local hs = self.handles
		local j = (n - 1) * 3 + 1
		hs[j]     = p
		hs[j + 1] = idx
		hs[j + 2] = epoch
	end

	function tok:_moved(p, old_idx, new_idx, epoch)
		self.moved = self.moved + 1
		self.last_moved = { pulse = p, old = old_idx, new = new_idx, epoch = epoch }

		-- Update our stored handle index so later cancellation works.
		local hs = self.handles
		for i = 1, self.nh do
			local j = (i - 1) * 3 + 1
			if hs[j] == p and hs[j + 1] == old_idx and hs[j + 2] == epoch then
				hs[j + 1] = new_idx
				return
			end
		end
	end

	function tok:_cancel_all()
		local hs = self.handles
		for i = 1, self.nh do
			local j = (i - 1) * 3 + 1
			local p     = hs[j]
			local idx   = hs[j + 1]
			local epoch = hs[j + 2]
			p:_unsubscribe_at(idx, self, epoch)
			hs[j], hs[j + 1], hs[j + 2] = nil, nil, nil
		end
		self.nh = 0
	end

	function tok:_woken_by(_pulse, sched_, epoch)
		self.woke = self.woke + 1
		self.last_wake_epoch = epoch

		-- Stale wake protection (mirrors runtime token behaviour)
		if epoch ~= self.expected_epoch then
			return
		end

		-- Cancel any remaining subscriptions before rescheduling.
		self:_cancel_all()

		sched_:schedule(self.fib)
	end

	return tok
end

----------------------------------------------------------------------
-- 1) Basic source pulse: subscribe(token, epoch) then signal schedules fibre once
----------------------------------------------------------------------

do
	local p = pulse.new(s)
	local fib = new_fiber('basic')
	local tok = new_token(fib)

	tok:_begin_wait(1)
	p:subscribe(tok, 1)

	assert_eq(p.kind, 'src', 'source pulse kind')
	assert_eq(p.nwait, 1, 'subscribe should add one waiter pair')
	assert_eq(tok.nh, 1, 'token should record one handle')

	p:signal()
	s:run()

	assert_eq(fib.ran, 1, 'fibre should run once')
	assert_eq(p.nwait, 0, 'pulse waiter list should be drained')
end

----------------------------------------------------------------------
-- 2) signal_if_waiting is a no-op when there are no waiters
----------------------------------------------------------------------

do
	local p = pulse.new(s)
	local fib = new_fiber('no-op')
	local tok = new_token(fib)

	-- No waiters: should do nothing
	p:signal_if_waiting()
	s:run()
	assert_eq(fib.ran, 0, 'no runs expected')

	-- Add a waiter then signal_if_waiting should behave like signal()
	tok:_begin_wait(1)
	p:subscribe(tok, 1)
	assert_eq(p.nwait, 1, 'waiter added')

	p:signal_if_waiting()
	s:run()
	assert_eq(fib.ran, 1, 'should run after signal_if_waiting with waiters')
	assert_eq(p.nwait, 0, 'drained')
end

----------------------------------------------------------------------
-- 3) Re-arm: subscribe again after drain
----------------------------------------------------------------------

do
	local p = pulse.new(s)
	local fib = new_fiber('rearm')
	local tok = new_token(fib)

	tok:_begin_wait(1)
	p:subscribe(tok, 1)
	p:signal()
	s:run()
	assert_eq(fib.ran, 1, 'ran once')

	tok:_begin_wait(2)
	p:subscribe(tok, 2)
	assert_eq(p.nwait, 1, 'subscribe should work after drain')
	p:signal()
	s:run()
	assert_eq(fib.ran, 2, 'ran twice after rearm')
end

----------------------------------------------------------------------
-- 4) Derived waitable: Pulse.any(p1, p2) subscribes to both; wake cancels the other
----------------------------------------------------------------------

do
	local p1 = pulse.new(s)
	local p2 = pulse.new(s)

	local fib = new_fiber('any')
	local tok = new_token(fib)

	local w = pulse.any(p1, p2)

	tok:_begin_wait(10)
	w:subscribe(tok, 10)

	assert_eq(p1.nwait, 1, 'p1 should have one waiter')
	assert_eq(p2.nwait, 1, 'p2 should have one waiter')
	assert_eq(tok.nh, 2, 'token should have two handles')

	-- Signal only p2: token should schedule fibre once and cancel p1 subscription.
	p2:signal()
	s:run()

	assert_eq(fib.ran, 1, 'fibre should run once from any-wake')
	assert_eq(p1.nwait, 0, 'p1 subscription should be cancelled on wake')
	assert_eq(p2.nwait, 0, 'p2 waiter list drained by signal')
end

----------------------------------------------------------------------
-- 5) any de-duplication: nested any and duplicates should not double-subscribe
----------------------------------------------------------------------

do
	local p1 = pulse.new(s)
	local p2 = pulse.new(s)

	local fib = new_fiber('dedupe')
	local tok = new_token(fib)

	local w1 = pulse.any(p1, p2)
	local w2 = pulse.any(w1, p1) -- duplicates p1; should remain one subscription per source

	tok:_begin_wait(20)
	w2:subscribe(tok, 20)

	assert_eq(p1.nwait, 1, 'p1 should be subscribed once')
	assert_eq(p2.nwait, 1, 'p2 should be subscribed once')
	assert_eq(tok.nh, 2, 'token should have exactly two handles')
end

----------------------------------------------------------------------
-- 6) Swap-with-tail unsubscribe: _unsubscribe_at triggers _moved on moved token
----------------------------------------------------------------------

do
	local p = pulse.new(s)
	local fibA = new_fiber('A')
	local fibB = new_fiber('B')
	local tA = new_token(fibA)
	local tB = new_token(fibB)

	tA:_begin_wait(1)
	tB:_begin_wait(1)

	p:subscribe(tA, 1) -- idx 1
	p:subscribe(tB, 1) -- idx 2

	assert_eq(p.nwait, 2, 'two waiters expected')
	assert_eq(tA.nh, 1, 'tA has one handle')
	assert_eq(tB.nh, 1, 'tB has one handle')

	-- Remove the first waiter by index; should move tB from 2->1 and call _moved.
	p:_unsubscribe_at(1, tA, 1)

	assert_eq(p.nwait, 1, 'one waiter remains after unsubscribe')
	assert_eq(tB.moved, 1, 'tB should receive one _moved callback')
	assert_true(tB.last_moved ~= nil, 'tB should have moved details')
	assert_eq(tB.last_moved.old, 2, 'moved from old idx 2')
	assert_eq(tB.last_moved.new, 1, 'moved to new idx 1')

	-- Now cancel tB using its stored (updated) index
	tB:_cancel_all()
	assert_eq(p.nwait, 0, 'pulse should have no waiters after cancelling remaining token')
end

----------------------------------------------------------------------
-- 7) Stale epoch wake: token ignores wake with mismatched epoch
----------------------------------------------------------------------

do
	local p = pulse.new(s)
	local fib = new_fiber('stale')
	local tok = new_token(fib)

	-- Subscribe at epoch 1...
	tok:_begin_wait(1)
	p:subscribe(tok, 1)
	assert_eq(p.nwait, 1, 'waiter added')

	-- ...but pretend the fibre has moved to a later wait epoch without cancelling (stale handle).
	tok.expected_epoch = 2

	p:signal()
	s:run()

	assert_eq(fib.ran, 0, 'stale wake should not schedule fibre')
	assert_eq(p.nwait, 0, 'signal drains waiters regardless')
end

----------------------------------------------------------------------
-- 8) any_from_array: avoids varargs and still behaves correctly
----------------------------------------------------------------------

do
	local p1 = pulse.new(s)
	local p2 = pulse.new(s)
	local fib = new_fiber('any_from_array')
	local tok = new_token(fib)

	local arr = { p1, p2 }
	local w = pulse.any_from_array(arr, 2)

	tok:_begin_wait(99)
	w:subscribe(tok, 99)

	assert_eq(p1.nwait, 1, 'p1 subscribed via any_from_array')
	assert_eq(p2.nwait, 1, 'p2 subscribed via any_from_array')

	p1:signal()
	s:run()
	assert_eq(fib.ran, 1, 'woke via any_from_array')
	assert_eq(p2.nwait, 0, 'other subscription cancelled on wake')
end

io.write('ok: pulse2\n')

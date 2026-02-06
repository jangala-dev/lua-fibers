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
-- - Tracks handles (pulse, idx, epoch) so it can cancel on wake
-- - On wake, cancels remaining handles and schedules its fibre (epoch-checked)
----------------------------------------------------------------------

local function new_token(fib)
	local tok = {
		fib = fib,
		expected_epoch = 0,

		-- Triples: [pulse, idx, epoch] per handle.
		hs = {},
		nh = 0,

		woke = 0,
		last_wake_epoch = nil,
	}

	function tok:_begin_wait(epoch)
		self.expected_epoch = epoch
		self.nh = 0
		self.woke = 0
		self.last_wake_epoch = nil
	end

	function tok:_add_handle(p, idx, epoch)
		local n = self.nh + 1
		self.nh = n
		local hs = self.hs
		local j = (n - 1) * 3 + 1
		hs[j]     = p
		hs[j + 1] = idx
		hs[j + 2] = epoch
	end

	function tok:_cancel_all()
		local hs = self.hs
		for i = 1, self.nh do
			local j = (i - 1) * 3 + 1
			local p     = hs[j]
			local idx   = hs[j + 1]
			local epoch = hs[j + 2]
			if p then
				p:_unsubscribe_at(idx, self, epoch)
			end
			hs[j], hs[j + 1], hs[j + 2] = nil, nil, nil
		end
		self.nh = 0
	end

	function tok:_woken_by(_pulse, sched_, epoch)
		self.woke = self.woke + 1
		self.last_wake_epoch = epoch

		-- Stale wake protection (mirrors runtime behaviour)
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

	assert_eq(p.n, 1, 'subscribe should add one slot')
	assert_eq(p.live, 1, 'subscribe should add one live waiter')
	assert_eq(tok.nh, 1, 'token should record one handle')

	p:signal()
	s:run()

	assert_eq(fib.ran, 1, 'fibre should run once')
	assert_eq(p.n, 0, 'pulse slots should be drained')
	assert_eq(p.live, 0, 'pulse live count should be zero after drain')
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
	assert_eq(p.live, 1, 'waiter added (live=1)')

	p:signal_if_waiting()
	s:run()
	assert_eq(fib.ran, 1, 'should run after signal_if_waiting with waiters')
	assert_eq(p.n, 0, 'drained')
	assert_eq(p.live, 0, 'drained live')
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
	assert_eq(p.live, 1, 'subscribe should work after drain (live=1)')
	p:signal()
	s:run()
	assert_eq(fib.ran, 2, 'ran twice after rearm')
end

----------------------------------------------------------------------
-- 4) Any view: subscribe to both; wake cancels the other subscription (tombstones)
----------------------------------------------------------------------

do
	local p1 = pulse.new(s)
	local p2 = pulse.new(s)

	local fib = new_fiber('any')
	local tok = new_token(fib)

	local arr = { p1, p2 }
	local w = pulse.any_view():set(arr, 2)

	tok:_begin_wait(10)
	w:subscribe(tok, 10)

	assert_eq(p1.live, 1, 'p1 should have one live waiter')
	assert_eq(p2.live, 1, 'p2 should have one live waiter')
	assert_eq(tok.nh, 2, 'token should have two handles')

	-- Signal only p2: token should schedule fibre once and cancel p1 subscription.
	p2:signal()
	s:run()

	assert_eq(fib.ran, 1, 'fibre should run once from any-wake')

	-- p2 was signalled, so it drains fully.
	assert_eq(p2.n, 0, 'p2 slots drained by signal')
	assert_eq(p2.live, 0, 'p2 live drained by signal')

	-- p1 should have been cancelled: tombstoned (n may remain, live must be 0).
	assert_eq(p1.live, 0, 'p1 subscription should be cancelled (live=0)')
end

----------------------------------------------------------------------
-- 5) Tombstone unsubscribe: _unsubscribe_at does not move indices; signal skips tombstones
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

	assert_eq(p.n, 2, 'two slots expected')
	assert_eq(p.live, 2, 'two live waiters expected')

	-- Tombstone the first waiter.
	local ok = p:_unsubscribe_at(1, tA, 1)
	assert_true(ok, 'unsubscribe should succeed')
	assert_eq(p.n, 2, 'slots do not shrink under tombstoning')
	assert_eq(p.live, 1, 'live should decrement under tombstoning')

	-- Now signal: should wake only B.
	p:signal()
	s:run()

	assert_eq(fibA.ran, 0, 'tombstoned waiter should not run')
	assert_eq(fibB.ran, 1, 'remaining waiter should run')
	assert_eq(p.n, 0, 'signal drains slots')
	assert_eq(p.live, 0, 'signal drains live')
end

----------------------------------------------------------------------
-- 6) Stale epoch wake: token ignores wake with mismatched epoch
----------------------------------------------------------------------

do
	local p = pulse.new(s)
	local fib = new_fiber('stale')
	local tok = new_token(fib)

	-- Subscribe at epoch 1...
	tok:_begin_wait(1)
	p:subscribe(tok, 1)
	assert_eq(p.live, 1, 'waiter added')

	-- ...but pretend the fibre has moved to a later wait epoch without cancelling.
	tok.expected_epoch = 2

	p:signal()
	s:run()

	assert_eq(fib.ran, 0, 'stale wake should not schedule fibre')
	assert_eq(p.n, 0, 'signal drains slots regardless')
	assert_eq(p.live, 0, 'signal drains live regardless')
end

----------------------------------------------------------------------
-- 7) Any view does not de-dupe: duplicates subscribe multiple times
----------------------------------------------------------------------

do
	local p1 = pulse.new(s)
	local p2 = pulse.new(s)

	local fib = new_fiber('dups')
	local tok = new_token(fib)

	local arr = { p1, p1, p2 }
	local w = pulse.any_view():set(arr, 3)

	tok:_begin_wait(7)
	w:subscribe(tok, 7)

	assert_eq(p1.live, 2, 'p1 should have two live waiters due to duplicates')
	assert_eq(p2.live, 1, 'p2 should have one live waiter')
	assert_eq(tok.nh, 3, 'token should have three handles')

	-- Wake via p2; token should cancel both p1 handles.
	p2:signal()
	s:run()

	assert_eq(fib.ran, 1, 'fibre should run once')
	assert_eq(p1.live, 0, 'both p1 handles should be cancelled (live=0)')
end

io.write('ok: pulse2\n')

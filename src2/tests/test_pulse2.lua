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
-- Implements the pulse subscriber surface expected by pulse2:
--   - pulse:subscribe_fibre(fib, epoch) will call fib:_add_handle(pulse, idx)
--   - pulse:signal() will call fib:_woken_by(pulse, sched, epoch)
-- Fibre cancels remaining handles on wake (epoch-checked) and schedules itself.
----------------------------------------------------------------------

local function new_fiber(name)
	local fib = {
		name = name or '<fib>',
		_queued = false,
		ran = 0,

		expected_epoch = 0,

		-- Pairs: [pulse, idx] per handle.
		hs = {},
		nh = 0,

		woke = 0,
		last_wake_epoch = nil,
	}

	function fib:run()
		self.ran = self.ran + 1
	end

	function fib:begin_wait(epoch)
		self.expected_epoch = epoch
		self.nh = 0
		self.woke = 0
		self.last_wake_epoch = nil
	end

	function fib:_add_handle(p, idx)
		local n = self.nh + 1
		self.nh = n
		local hs = self.hs
		local j = (n - 1) * 2 + 1
		hs[j]     = p
		hs[j + 1] = idx
	end

	function fib:_cancel_all(epoch)
		local hs = self.hs
		for i = 1, self.nh do
			local j = (i - 1) * 2 + 1
			local p   = hs[j]
			local idx = hs[j + 1]
			if p then
				p:_unsubscribe_at(idx, self, epoch)
			end
			hs[j], hs[j + 1] = nil, nil
		end
		self.nh = 0
	end

	function fib:_woken_by(_pulse, sched_, epoch)
		self.woke = self.woke + 1
		self.last_wake_epoch = epoch

		-- Stale wake protection (mirrors runtime behaviour)
		if epoch ~= self.expected_epoch then
			return
		end

		-- Cancel any remaining subscriptions before rescheduling.
		self:_cancel_all(epoch)

		sched_:schedule(self)
	end

	return fib
end

----------------------------------------------------------------------
-- 1) Basic source pulse: subscribe_fibre(fib, epoch) then signal schedules fibre once
----------------------------------------------------------------------

do
	local p = pulse.new(s)
	local fib = new_fiber('basic')

	fib:begin_wait(1)
	p:subscribe_fibre(fib, 1)

	assert_eq(p.n, 1, 'subscribe should add one slot')
	assert_eq(p.live, 1, 'subscribe should add one live waiter')
	assert_eq(fib.nh, 1, 'fibre should record one handle')

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

	-- No waiters: should do nothing
	p:signal_if_waiting()
	s:run()
	assert_eq(fib.ran, 0, 'no runs expected')

	-- Add a waiter then signal_if_waiting should behave like signal()
	fib:begin_wait(1)
	p:subscribe_fibre(fib, 1)
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

	fib:begin_wait(1)
	p:subscribe_fibre(fib, 1)
	p:signal()
	s:run()
	assert_eq(fib.ran, 1, 'ran once')

	fib:begin_wait(2)
	p:subscribe_fibre(fib, 2)
	assert_eq(p.live, 1, 'subscribe should work after drain (live=1)')
	p:signal()
	s:run()
	assert_eq(fib.ran, 2, 'ran twice after rearm')
end

----------------------------------------------------------------------
-- 4) Multi-wait: subscribe to both pulses; wake cancels the other subscription (tombstones)
----------------------------------------------------------------------

do
	local p1 = pulse.new(s)
	local p2 = pulse.new(s)

	local fib = new_fiber('union')

	fib:begin_wait(10)
	p1:subscribe_fibre(fib, 10)
	p2:subscribe_fibre(fib, 10)

	assert_eq(p1.live, 1, 'p1 should have one live waiter')
	assert_eq(p2.live, 1, 'p2 should have one live waiter')
	assert_eq(fib.nh, 2, 'fibre should have two handles')

	-- Signal only p2: fibre should schedule once and cancel p1 subscription.
	p2:signal()
	s:run()

	assert_eq(fib.ran, 1, 'fibre should run once from union-wake')

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

	fibA:begin_wait(1)
	fibB:begin_wait(1)

	p:subscribe_fibre(fibA, 1) -- idx 1
	p:subscribe_fibre(fibB, 1) -- idx 2

	assert_eq(p.n, 2, 'two slots expected')
	assert_eq(p.live, 2, 'two live waiters expected')

	-- Tombstone the first waiter.
	local ok = p:_unsubscribe_at(1, fibA, 1)
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
-- 6) Stale epoch wake: fibre ignores wake with mismatched epoch
----------------------------------------------------------------------

do
	local p = pulse.new(s)
	local fib = new_fiber('stale')

	-- Subscribe at epoch 1...
	fib:begin_wait(1)
	p:subscribe_fibre(fib, 1)
	assert_eq(p.live, 1, 'waiter added')

	-- ...but pretend the fibre has moved to a later wait epoch without cancelling.
	fib.expected_epoch = 2

	p:signal()
	s:run()

	assert_eq(fib.ran, 0, 'stale wake should not schedule fibre')
	assert_eq(p.n, 0, 'signal drains slots regardless')
	assert_eq(p.live, 0, 'signal drains live regardless')
end

----------------------------------------------------------------------
-- 7) Duplicate subscriptions: subscribing twice to the same pulse creates two slots
----------------------------------------------------------------------

do
	local p1 = pulse.new(s)
	local p2 = pulse.new(s)

	local fib = new_fiber('dups')

	fib:begin_wait(7)
	p1:subscribe_fibre(fib, 7)
	p1:subscribe_fibre(fib, 7)
	p2:subscribe_fibre(fib, 7)

	assert_eq(p1.live, 2, 'p1 should have two live waiters due to duplicates')
	assert_eq(p2.live, 1, 'p2 should have one live waiter')
	assert_eq(fib.nh, 3, 'fibre should have three handles')

	-- Wake via p2; fibre should cancel both p1 handles.
	p2:signal()
	s:run()

	assert_eq(fib.ran, 1, 'fibre should run once')
	assert_eq(p1.live, 0, 'both p1 handles should be cancelled (live=0)')
end

io.write('ok: pulse2\n')

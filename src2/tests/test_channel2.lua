-- tests/test_channel2.lua
package.path = '../?.lua;' .. package.path

local function reload_all()
	for _, m in ipairs({
		'fibers.runtime2', 'fibers.sched2', 'fibers.pulse2', 'fibers.op2', 'fibers.channel2'
	}) do
		package.loaded[m] = nil
	end
end

local function assert_eq(a, b, msg)
	if a ~= b then error((msg or 'assert_eq failed') .. (': got ' .. tostring(a) .. ', want ' .. tostring(b)), 2) end
end

local function assert_true(x, msg)
	if not x then error(msg or 'assert_true failed', 2) end
end

local function assert_waiting(fib, msg)
	assert_true(fib._waiting_epoch ~= nil, msg or 'fiber should be waiting')
end

-- Basic rendezvous: one put and one get complete and transfer a value.
do
	reload_all()
	local runtime = require 'fibers.runtime2'
	local op2     = require 'fibers.op2'
	local chan    = require 'fibers.channel2'

	local ch = chan.new()
	local got
	local sent = false

	runtime.spawn(function ()
		got = op2.perform(ch:get_op())
	end, 'recv')

	runtime.spawn(function ()
		op2.perform(ch:put_op('X'))
		sent = true
	end, 'send')

	runtime.main()

	assert_eq(got, 'X')
	assert_eq(sent, true)
end

-- Atomicity under all(get1, get2):
-- If only one sender exists, it must not complete early; once the second sender appears,
-- the transaction commits and both senders complete.
do
	reload_all()
	local runtime = require 'fibers.runtime2'
	local op2     = require 'fibers.op2'
	local chan    = require 'fibers.channel2'

	local ch1 = chan.new()
	local ch2 = chan.new()

	local s1_done, s2_done = false, false
	local recv_done = false
	local r1, r2

	runtime.spawn(function ()
		op2.perform(ch1:put_op('A'))
		s1_done = true
	end, 'sender1')

	runtime.spawn(function ()
		r1, r2 = op2.perform(op2.all(ch1:get_op(), ch2:get_op()))
		recv_done = true
	end, 'recv_all')

	-- Drive runnable work without invoking deadlock detection.
	local sched = runtime.scheduler()
	while sched:step() do end

	-- At this point only sender1 exists, so nobody should have completed.
	assert_eq(s1_done, false)
	assert_eq(recv_done, false)

	-- Now introduce sender2; the transaction can complete.
	runtime.spawn(function ()
		op2.perform(ch2:put_op('B'))
		s2_done = true
	end, 'sender2')

	while sched:step() do end

	assert_eq(s1_done, true)
	assert_eq(s2_done, true)
	assert_eq(recv_done, true)

	-- all returns packed results per arm
	assert_eq(type(r1), 'table'); assert_eq(r1[1], 'A'); assert_eq(r1.n, 1)
	assert_eq(type(r2), 'table'); assert_eq(r2[1], 'B'); assert_eq(r2.n, 1)

	assert_eq(next(runtime._live), nil, 'no live fibres should remain')
end

-- and_then (channel): if LHS get previews ready but RHS is pending, it must:
--   * abort LHS reservation (do not hold it)
--   * wait on (rhs_pulse OR lhs_watch_pulse)
do
	reload_all()
	local runtime = require 'fibers.runtime2'
	local pulse   = require 'fibers.pulse2'
	local op2     = require 'fibers.op2'
	local chan    = require 'fibers.channel2'

	local sched = runtime.scheduler()
	local ch    = chan.new()

	local pR = pulse.new(sched)
	local rhs_ready = false
	local out

	-- Sender: will enqueue put and block (no receiver yet).
	runtime.spawn(function()
		op2.perform(ch:put_op('X'))
	end, 'sender')

	-- Receiver: get is ready once the put is enqueued; RHS remains pending on pR.
	local f = runtime.spawn(function()
		out = op2.perform(ch:get_op():and_then(function(v)
			return setmetatable({
				preview = function(self)
					if not rhs_ready then return pR, nil, nil end
					return nil, self, { n = 1, v .. '!' }
				end,
				commit = function(self, offer)
					assert_eq(offer, self)
					return { n = 1, v .. '!' }
				end,
				abort = function() end,
			}, op2.Op)
		end))
	end, 'and_then')

	-- Step 1: run sender, so put enqueues and yields on ch.pulse.
	assert_eq(runtime.step(), 'ran')

	-- Step 2: run receiver; LHS preview-ready; RHS pending => wait on (pR OR ch.pulse).
	assert_eq(runtime.step(), 'ran')
	assert_waiting(f)

	-- Subscriptions must reach both pulses.
	assert_true(ch.pulse:has_waiters(), 'lhs watch pulse (channel pulse) should have waiters')
	assert_true(pR:has_waiters(), 'rhs pulse should have waiters')

	-- Now make RHS ready and signal; receiver retries, commits get then RHS; sender completes too.
	rhs_ready = true
	pR:signal()
	runtime.main()

	assert_eq(out, 'X!')
end

-- choice does not lose the losing message:
-- choice(get1, get2) returns one value; the other value remains available to a later get.
do
	reload_all()
	local runtime = require 'fibers.runtime2'
	local op2     = require 'fibers.op2'
	local chan    = require 'fibers.channel2'

	local ch1 = chan.new()
	local ch2 = chan.new()

	local v1, v2
	local s1_done, s2_done = false, false

	runtime.spawn(function ()
		op2.perform(ch1:put_op('LEFT'))
		s1_done = true
	end, 's1')

	runtime.spawn(function ()
		op2.perform(ch2:put_op('RIGHT'))
		s2_done = true
	end, 's2')

	runtime.spawn(function ()
		v1 = op2.perform(op2.choice(ch1:get_op(), ch2:get_op()))
		if v1 == 'LEFT' then
			v2 = op2.perform(ch2:get_op())
		else
			v2 = op2.perform(ch1:get_op())
		end
	end, 'chooser_then_drain')

	runtime.main()

	-- Both sends must complete; both values must be observed exactly once.
	assert_eq(s1_done, true)
	assert_eq(s2_done, true)
	assert((v1 == 'LEFT' and v2 == 'RIGHT') or (v1 == 'RIGHT' and v2 == 'LEFT'),
		('unexpected values: v1=%s v2=%s'):format(tostring(v1), tostring(v2)))
end

io.write('ok: channel2\n')

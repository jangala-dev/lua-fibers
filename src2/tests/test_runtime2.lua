-- tests/test_runtime2.lua
package.path = '../?.lua;' .. package.path

local function reload()
	for _, m in ipairs({ 'fibers.runtime2', 'fibers.sched2', 'fibers.pulse2' }) do
		package.loaded[m] = nil
	end
	local runtime = require 'fibers.runtime2'
	local pulse   = require 'fibers.pulse2'
	return runtime, pulse
end

local runtime, pulse = reload()

local function assert_eq(a, b, msg)
	if a ~= b then
		error((msg or 'assert_eq failed') .. (': got ' .. tostring(a) .. ', want ' .. tostring(b)), 2)
	end
end

local function assert_true(x, msg)
	if not x then error(msg or 'assert_true failed', 2) end
end

----------------------------------------------------------------------
-- 1) Basic wait/wake: await(p) subscribes token, yield WAIT, p.signal schedules
----------------------------------------------------------------------

do
	local p = pulse.new(runtime.scheduler())
	local resumed = false

	local f = runtime.spawn(function ()
		runtime.await(p)
		resumed = true
	end, 'waiter')

	assert_eq(runtime.step(), 'ran')
	assert_eq(f._waiting_waitable, p, 'fiber should be waiting on pulse')
	assert_true(f._waiting_token ~= nil, 'fiber should have a waiting token')
	assert_true(f._waiting_epoch ~= nil, 'fiber should have a waiting epoch')

	p:signal()
	runtime.main()

	assert_eq(resumed, true, 'fiber should have resumed and completed')
	assert_eq(next(runtime._live), nil, 'no live fibres should remain')
end

----------------------------------------------------------------------
-- 2) await(Pulse.any(p1,p2)) wakes on either; cancels the other subscription
----------------------------------------------------------------------

do
	runtime, pulse = reload()

	local sched = runtime.scheduler()
	local p1 = pulse.new(sched)
	local p2 = pulse.new(sched)
	local w  = pulse.any(p1, p2)

	local resumed = false
	local f = runtime.spawn(function ()
		runtime.await(w)
		resumed = true
	end, 'any_waiter')

	assert_eq(runtime.step(), 'ran')
	assert_eq(f._waiting_waitable, w, 'fiber should be waiting on derived any waitable')

	-- Signal only p2; should wake and cancel p1 subscription.
	p2:signal()
	runtime.main()

	assert_eq(resumed, true, 'fiber should have resumed from any waitable')

	-- Best-effort check that both source pulses have no waiters.
	-- (The token cancels remaining subscriptions on wake.)
	assert_eq(p1.nwait, 0, 'p1 should have no waiters after wake/cancel')
	assert_eq(p2.nwait, 0, 'p2 should have no waiters after signal drains')
	assert_eq(next(runtime._live), nil, 'no live fibres should remain')
end

----------------------------------------------------------------------
-- 3) Deadlock detection: no runnable tasks and all live fibres waiting must error
----------------------------------------------------------------------

do
	runtime, pulse = reload()

	local p = pulse.new(runtime.scheduler())
	runtime.spawn(function () runtime.await(p) end, 'deadlocker')

	assert_eq(runtime.step(), 'ran')

	local ok, err = pcall(runtime.step)
	assert_eq(ok, false, 'expected deadlock error')
	assert(err:match('deadlock: no runnable tasks %(all fibres appear to be waiting%)')
		or err:match('deadlock: no runnable tasks %(all fibers appear to be waiting%)'),
		err)
end

----------------------------------------------------------------------
-- 4) Internal bookkeeping error path: live fibre neither runnable nor waiting
--    (We force it by clearing waiting fields after it blocks.)
----------------------------------------------------------------------

do
	runtime, pulse = reload()

	local p = pulse.new(runtime.scheduler())
	local f = runtime.spawn(function () runtime.await(p) end, 'broken')

	assert_eq(runtime.step(), 'ran')
	assert_true(f._waiting_waitable ~= nil, 'should be waiting')

	-- Break the invariant deliberately.
	f._waiting_waitable = nil
	f._waiting_token    = nil
	f._waiting_epoch    = nil

	local ok, err = pcall(runtime.step)
	assert_eq(ok, false, 'expected bookkeeping error')
	assert(err:match('deadlock: no runnable tasks %(live fibre not runnable and not waiting%)'), err)
end

io.write('ok: runtime2\n')

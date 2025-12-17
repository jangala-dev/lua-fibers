--- Tests the Oneshot implementation.
print('testing: fibers.oneshot')

-- look one level up
package.path = '../src/?.lua;' .. package.path

local oneshot = require 'fibers.oneshot'

local fibers  = require 'fibers'
local op      = require 'fibers.op'
local cond    = require 'fibers.cond'
local runtime = require 'fibers.runtime'
local safe    = require 'coxpcall'

local function count_live_waiters(os)
	-- Patched oneshot: waiters are records { fn = function|nil }.
	-- Older oneshot (pre-patch): waiters were bare functions.
	local ws = os.waiters or {}
	local n = 0
	for i = 1, #ws do
		local v = ws[i]
		if type(v) == 'function' then
			n = n + 1
		elseif type(v) == 'table' and type(v.fn) == 'function' then
			n = n + 1
		end
	end
	return n
end

local function assert_equal(actual, expected, msg)
	if actual ~= expected then
		error((msg or 'assert_equal failed') ..
			(': expected %s, got %s'):format(tostring(expected), tostring(actual)), 2)
	end
end

local function assert_true(v, msg)
	if not v then error(msg or 'assert_true failed', 2) end
end

local function assert_false(v, msg)
	if v then error(msg or 'assert_false failed', 2) end
end

local function run_test(name, fn)
	local ok, err = safe.pcall(fn)
	if ok then
		print(name .. ': ok')
		return
	end
	error(name .. ': FAILED\n' .. tostring(err), 0)
end

local function test_waiters_run_on_signal_and_clear()
	local os = oneshot.new()
	local log = {}

	os:add_waiter(function () log[#log + 1] = 'w1' end)
	os:add_waiter(function () log[#log + 1] = 'w2' end)

	assert_equal(#log, 0, 'waiters should not run before signal')
	assert_false(os:is_triggered(), 'should not be triggered before signal')

	os:signal()

	assert_true(os:is_triggered(), 'should be triggered after signal')
	assert_equal(#log, 2, 'expected two waiter runs')
	assert_equal(log[1], 'w1')
	assert_equal(log[2], 'w2')
	assert_equal(count_live_waiters(os), 0, 'no live waiters should remain after signal')
end

local function test_add_waiter_after_signal_runs_immediately()
	local os = oneshot.new()
	os:signal()

	local ran = false
	os:add_waiter(function () ran = true end)

	assert_true(ran, 'waiter should run immediately after signal')
	assert_equal(count_live_waiters(os), 0, 'no live waiters should be stored after signal')
end

local function test_signal_is_idempotent()
	local os = oneshot.new()
	local n = 0

	os:add_waiter(function () n = n + 1 end)

	os:signal()
	os:signal()
	os:signal()

	assert_equal(n, 1, 'waiter must run only once')
end

local function test_on_after_signal_runs_after_waiters()
	local log = {}
	local os = oneshot.new(function ()
		log[#log + 1] = 'after'
	end)

	os:add_waiter(function () log[#log + 1] = 'w1' end)
	os:add_waiter(function () log[#log + 1] = 'w2' end)

	os:signal()

	assert_equal(#log, 3)
	assert_equal(log[1], 'w1')
	assert_equal(log[2], 'w2')
	assert_equal(log[3], 'after')
end

local function test_add_waiter_returns_canceller_and_cancel_prevents_run()
	local os = oneshot.new()
	local ran = false

	local cancel = os:add_waiter(function () ran = true end)
	assert_true(type(cancel) == 'function', 'expected add_waiter to return a canceller function')

	-- idempotent
	cancel()
	cancel()

	os:signal()

	assert_false(ran, 'cancelled waiter must not run on signal')
	assert_equal(count_live_waiters(os), 0, 'no live waiters should remain after signal')
end

local function test_add_waiter_after_signal_returns_noop_canceller()
	local os = oneshot.new()
	os:signal()

	local ran = false
	local cancel = os:add_waiter(function () ran = true end)

	assert_true(ran, 'waiter should run immediately')
	assert_true(type(cancel) == 'function', 'expected a canceller function')
	cancel()
	cancel()
end

local function test_reentrant_add_waiter_during_signal()
	local os = oneshot.new()
	local log = {}

	os:add_waiter(function ()
		log[#log + 1] = 'a'
		os:add_waiter(function ()
			log[#log + 1] = 'b'
		end)
	end)

	os:signal()

	assert_equal(#log, 2)
	assert_equal(log[1], 'a')
	assert_equal(log[2], 'b')
end

local function test_integration_choice_cleans_losing_cond_waiter()
	-- This asserts the specific regression you were targeting: if a wait is abandoned,
	-- its waiter closure should not remain referenced by the oneshot.
	local c1 = cond.new()
	local c2 = cond.new()

	local chosen = nil

	fibers.spawn(function ()
		chosen = fibers.perform(op.choice(
			c1:wait_op():wrap(function () return 'c1' end),
			c2:wait_op():wrap(function () return 'c2' end)
		))
	end)

	-- Allow the spawned fiber to run and block, registering both waiters.
	runtime.yield()

	assert_equal(count_live_waiters(c1._os), 1, 'expected c1 to have 1 live waiter while blocked')
	assert_equal(count_live_waiters(c2._os), 1, 'expected c2 to have 1 live waiter while blocked')

	-- Complete one arm.
	c1:signal()

	-- Allow completion to propagate.
	runtime.yield()

	assert_equal(chosen, 'c1', 'expected choice winner to be c1')

	-- Winner and loser should not retain live waiter closures after completion.
	assert_equal(count_live_waiters(c1._os), 0, 'expected c1 to have 0 live waiters after signal')
	assert_equal(count_live_waiters(c2._os), 0, 'expected c2 to have 0 live waiters after losing the choice')
end

local function main()
	local tests = {
		{ 'Basic signal behaviour',                   test_waiters_run_on_signal_and_clear },
		{ 'add_waiter after signal runs immediately', test_add_waiter_after_signal_runs_immediately },
		{ 'signal idempotence',                       test_signal_is_idempotent },
		{ 'on_after_signal ordering',                 test_on_after_signal_runs_after_waiters },
		{ 'canceller prevents run',                   test_add_waiter_returns_canceller_and_cancel_prevents_run },
		{ 'noop canceller after signal',              test_add_waiter_after_signal_returns_noop_canceller },
		{ 're-entrant add_waiter during signal',      test_reentrant_add_waiter_during_signal },
		{ 'integration: choice cleans losing waiter', test_integration_choice_cleans_losing_cond_waiter },
	}

	for _, t in ipairs(tests) do
		run_test(t[1], t[2])
	end
end

fibers.run(main)

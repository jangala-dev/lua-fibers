--- Tests the Waitgroup implementation.
print('testing: fibers.waitgroup')

-- look one level up
package.path = '../src/?.lua;' .. package.path

-- test_waitgroup.lua
local fibers = require 'fibers'
local sleep = require 'fibers.sleep'
local waitgroup = require 'fibers.waitgroup'
local time = require 'fibers.utils.time'

local perform, choice = fibers.perform, fibers.choice

local function test_nowait()
	local wg = waitgroup.new()
	local task = wg:wait_op():or_else(function ()
		error('blocked on empty waitgroup')
	end)
	perform(task)
	print('No wait test: ok')
end

local function test_simple()
	local wg = waitgroup.new()
	local numFibers = 5

	-- Spawn fibers and add to the waitgroup
	for _ = 1, numFibers do
		wg:add(1)
		fibers.spawn(function ()
			sleep.sleep(0.1) -- Simulate some work
			wg:done()
		end)
	end

	perform(
		wg:wait_op():wrap(function ()
			error("waitgroup didn't block when it should have")
		end)
		:or_else(function () end)
	)

	wg:wait()
	print('Simple test: ok')
end

local function test_reuse()
	local wg = waitgroup.new()
	-- Spawn fibers and add to the waitgroup
	wg:add(1)
	fibers.spawn(function ()
		sleep.sleep(0.1) -- Simulate some work
		wg:done()
	end)

	wg:wait()

	wg:add(1)
	local blocked = false
	fibers.spawn(function ()
		sleep.sleep(0.1) -- Simulate some work
		wg:done()
	end)

	perform(
		wg:wait_op()
		:or_else(function () blocked = true end)
	)
	assert(blocked, 'Reused Waitgroup should block.')

	wg:wait()

	print('Reuse test: ok')
end


local function test_complex()
	local wg = waitgroup.new()
	local numFibers = 5

	local function one_sec_work(w)
		w:add(1)
		fibers.spawn(function ()
			sleep.sleep(0.1) -- Simulate some work
			w:done()
		end)
	end

	local start = time.monotonic()

	-- Spawn fibers and add to the waitgroup
	for _ = 1, numFibers do one_sec_work(wg) end

	local done = false

	local extra_work_done = false
	local function extra_work()
		if not extra_work_done then
			extra_work_done = true
			one_sec_work(wg)
		end
	end

	while not done do
		perform(
			choice(
				wg:wait_op():wrap(function () done = true end),
				sleep.sleep_op(0.09):wrap(extra_work)
			)
		)
	end

	assert(time.monotonic() - start > 0.05)
	print('Complex test: ok')
end


local function main()
	test_nowait()
	test_simple()
	test_reuse()
	test_complex()
end

-- Start the main function in fiber context
fibers.run(main)

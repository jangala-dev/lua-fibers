print('testing: fibers.channel')

package.path = '../src/?.lua;' .. package.path

local fibers = require 'fibers'
local channel = require 'fibers.channel'
local op = require 'fibers.op'
local sleep = require 'fibers.sleep'

local function test_unbuffered()
	local chan = channel.new()
	fibers.spawn(function () chan:put(42) end)
	assert(chan:get() == 42, 'basic transfer')

	local received, signal = true, channel.new()
	fibers.spawn(function ()
		received = chan:get()
		signal:put(true)
	end)
	fibers.spawn(function ()
		chan:put(nil)
		signal:put(true)
	end)
	signal:get()
	signal:get()
	assert(received == nil, 'blocking transfer')
	print('Unbuffered passed')
end

local function test_buffered()
	local chan, signal = channel.new(2), channel.new()

	fibers.spawn(function ()
		for i = 1, 4 do
			chan:put(i)
		end
		signal:put(true)
	end)
	fibers.spawn(function ()
		for i = 1, 2 do
			assert(chan:get() == i)
		end
	end)

	signal:get()
	fibers.spawn(function ()
		chan:put(5)
		signal:put(true)
	end)
	assert(chan:get() == 3)
	signal:get()
	assert(chan:get() == 4)
	assert(chan:get() == 5)
	print('Bounded buffered passed')
end

local function test_unbounded()
	local chan = channel.new(math.huge)
	for i = 1, 1000 do chan:put(i) end
	for i = 1, 1000 do assert(chan:get() == i) end

	local blocked = true
	fibers.spawn(function ()
		chan:get()
		blocked = false
	end)

	-- At this point, there is no value available, so get() must have blocked.
	assert(blocked, 'get should block')

	-- Now provide a value so the spawned fiber can complete.
	chan:put(123)

	print('Unbounded passed')
end

local function test_concurrent()
	local chan, signal, results = channel.new(1), channel.new(), {}
	fibers.spawn(function ()
		for i = 1, 11 do chan:put(i) end
		signal:put()
	end)
	fibers.spawn(function ()
		for _ = 1, 10 do table.insert(results, chan:get()) end
		signal:put()
	end)
	signal:get()
	signal:get()
	for i = 1, 10 do assert(results[i] == i) end
	print('Concurrent passed')
end


local function test_losing_choice_send_waiter_is_unlinked()
	local chan = channel.new()

	local tag = fibers.perform(op.choice(
		chan:put_op('lost'):wrap(function () return 'sent' end),
		sleep.sleep_op(0.01):wrap(function () return 'timeout' end)
	))
	assert(tag == 'timeout', 'expected timeout arm to win')
	assert(chan.putq:length() == 0, 'losing send waiter should be unlinked')

	fibers.spawn(function () chan:put('ok') end)
	assert(chan:get() == 'ok', 'channel should still work after losing send cleanup')
	print('Losing choice send waiter cleanup passed')
end

local function test_losing_choice_recv_waiter_is_unlinked()
	local chan = channel.new()

	local tag = fibers.perform(op.choice(
		chan:get_op():wrap(function () return 'got' end),
		sleep.sleep_op(0.01):wrap(function () return 'timeout' end)
	))
	assert(tag == 'timeout', 'expected timeout arm to win')
	assert(chan.getq:length() == 0, 'losing receive waiter should be unlinked')

	fibers.spawn(function () chan:put('ok') end)
	assert(chan:get() == 'ok', 'channel should still work after losing receive cleanup')
	print('Losing choice receive waiter cleanup passed')
end

local function main()
	test_unbuffered()
	test_buffered()
	test_unbounded()
	test_concurrent()
	test_losing_choice_send_waiter_is_unlinked()
	test_losing_choice_recv_waiter_is_unlinked()
	print('All channel tests passed!')
end

fibers.run(main)

-- tests/bench.lua

package.path = '../?.lua;' .. package.path

local runtime = require 'fibers.runtime2'
local op      = require 'fibers.op2'
local chan    = require 'fibers.channel2'

local nixio = require 'nixio'

local tonumber = tonumber
local format   = string.format

local N = tonumber(arg and arg[1]) or 100000

local function make_chan()
	return chan.new()
end

local function report(label, dt)
	local mps = (dt > 0) and (N / dt) or math.huge
	io.stdout:write(format('%-28s  N=%d  time=%.6fs  rate=%.0f msg/s\n', label, N, dt, mps))
	return dt, mps
end

-- Baseline: primitives only (put/get op, no choice wrapper).
local function bench_prim(label, make_channel, perform_fn)
	local ch        = make_channel()
	local done_recv = make_channel()
	local done_send = make_channel()

	runtime.spawn(function ()
		for _ = 1, N do
			perform_fn(ch:get_op())
		end
		perform_fn(done_recv:put_op(true))
	end)

	runtime.spawn(function ()
		for _ = 1, N do
			perform_fn(ch:put_op(true))
		end
		perform_fn(done_send:put_op(true))
	end)

	local t0 = nixio.gettime()
	perform_fn(done_recv:get_op())
	perform_fn(done_send:get_op())
	local t1 = nixio.gettime()

	return report(label, t1 - t0)
end

-- Two-arm choice: receiver does choice(getA, getB); sender alternates between A and B.
local function bench_choice_two_channels(label, make_channel, perform_fn, choice_fn)
	local chA       = make_channel()
	local chB       = make_channel()
	local done_recv = make_channel()
	local done_send = make_channel()

	runtime.spawn(function ()
		for _ = 1, N do
			perform_fn(choice_fn(chA:get_op(), chB:get_op()))
		end
		perform_fn(done_recv:put_op(true))
	end)

	runtime.spawn(function ()
		for i = 1, N do
			if (i % 2) == 0 then
				perform_fn(chA:put_op(1))
			else
				perform_fn(chB:put_op(1))
			end
		end
		perform_fn(done_send:put_op(true))
	end)

	-- drain_scheduler(5)

	local t0 = nixio.gettime()
	perform_fn(done_recv:get_op())
	perform_fn(done_send:get_op())
	local t1 = nixio.gettime()

	-- drain_scheduler(10)
	return report(label, t1 - t0)
end

-- Runner fiber: benchmarks must run inside a fiber because perform blocks.
runtime.spawn(function ()
	io.stdout:write(format('Benchmarks (single-threaded scheduler), N=%d\n', N))
	io.stdout:write('------------------------------------------------------------\n')

	collectgarbage('collect')
	bench_prim('op2 prim channel2', make_chan, op.perform)

	io.stdout:write('\n')

	collectgarbage('collect')
	bench_choice_two_channels('op2 choice(getA,getB)', make_chan, op.perform, op.choice)

	io.stdout:write('------------------------------------------------------------\n')
end)

runtime.main()

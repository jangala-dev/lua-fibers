-- tests/bench.lua
--
-- Benchmarks: op1 channel vs op2 channel2
--   * primitive rendezvous send/recv
--   * choice(get, never)
--   * choice(getA, getB) with alternating sends
--
-- Run:
--   luajit tests/bench.lua
--   luajit tests/bench.lua 200000   -- override N

package.path = '../src/?.lua;' .. package.path

local runtime  = require 'fibers.runtime'

local op1      = require 'fibers.op'
local chan1    = require 'fibers.channel'

local op2      = require 'fibers.op2'
local chan2    = require 'fibers.channel2'

local tonumber = tonumber
local format   = string.format

local N = tonumber(arg and arg[1]) or 100000

-- For repeatability where op1 choice probes randomly.
math.randomseed(1)

local function drain_scheduler(steps)
	for _ = 1, (steps or 20) do runtime.yield() end
end

local function make_chan1()
	-- Unbuffered rendezvous
	return chan1.new(0)
end

local function make_chan2()
	-- Unbuffered rendezvous (channel2 is always unbuffered in the provided code)
	return chan2.new()
end

local function report(label, dt)
	local mps = (dt > 0) and (N / dt) or math.huge
	io.stdout:write(format("%-28s  N=%d  time=%.6fs  rate=%.0f msg/s\n", label, N, dt, mps))
	return dt, mps
end

-- Baseline: primitives only (put/get op, no choice wrapper).
local function bench_prim(label, make_channel, perform_fn)
	local ch        = make_channel()
	local done_recv = make_channel()
	local done_send = make_channel()

	runtime.spawn_raw(function ()
		for _ = 1, N do
			perform_fn(ch:get_op())
		end
		perform_fn(done_recv:put_op(true))
	end)

	runtime.spawn_raw(function ()
		for _ = 1, N do
			perform_fn(ch:put_op(1))
		end
		perform_fn(done_send:put_op(true))
	end)

	drain_scheduler(5)

	local t0 = runtime.now()
	perform_fn(done_recv:get_op())
	perform_fn(done_send:get_op())
	local t1 = runtime.now()

	drain_scheduler(10)
	return report(label, t1 - t0)
end

-- Choice wrapper on receive side: choice(get, never)
local function bench_choice_get_never(label, make_channel, perform_fn, choice_fn, never_fn)
	local ch        = make_channel()
	local done_recv = make_channel()
	local done_send = make_channel()

	runtime.spawn_raw(function ()
		local never_op = never_fn()
		for _ = 1, N do
			perform_fn(choice_fn(ch:get_op(), never_op))
		end
		perform_fn(done_recv:put_op(true))
	end)

	runtime.spawn_raw(function ()
		for _ = 1, N do
			perform_fn(ch:put_op(1))
		end
		perform_fn(done_send:put_op(true))
	end)

	drain_scheduler(5)

	local t0 = runtime.now()
	perform_fn(done_recv:get_op())
	perform_fn(done_send:get_op())
	local t1 = runtime.now()

	drain_scheduler(10)
	return report(label, t1 - t0)
end

-- Two-arm choice: receiver does choice(getA, getB); sender alternates between A and B.
local function bench_choice_two_channels(label, make_channel, perform_fn, choice_fn)
	local chA       = make_channel()
	local chB       = make_channel()
	local done_recv = make_channel()
	local done_send = make_channel()

	runtime.spawn_raw(function ()
		for _ = 1, N do
			perform_fn(choice_fn(chA:get_op(), chB:get_op()))
		end
		perform_fn(done_recv:put_op(true))
	end)

	runtime.spawn_raw(function ()
		for i = 1, N do
			if (i % 2) == 0 then
				perform_fn(chA:put_op(1))
			else
				perform_fn(chB:put_op(1))
			end
		end
		perform_fn(done_send:put_op(true))
	end)

	drain_scheduler(5)

	local t0 = runtime.now()
	perform_fn(done_recv:get_op())
	perform_fn(done_send:get_op())
	local t1 = runtime.now()

	drain_scheduler(10)
	return report(label, t1 - t0)
end

-- Runner fibre: benchmarks must run inside a fibre because perform blocks.
runtime.spawn_raw(function ()
	io.stdout:write(format("Benchmarks (single-threaded scheduler), N=%d\n", N))
	io.stdout:write("------------------------------------------------------------\n")

	collectgarbage('collect')
	bench_prim("op1 prim channel", make_chan1, op1.perform_raw)

	collectgarbage('collect')
	bench_prim("op2 prim channel2", make_chan2, op2.perform)

	io.stdout:write("\n")

	collectgarbage('collect')
	bench_choice_get_never("op1 choice(get,never)", make_chan1, op1.perform_raw, op1.choice, op1.never)

	collectgarbage('collect')
	bench_choice_get_never("op2 choice(get,never)", make_chan2, op2.perform, op2.choice, op2.never)

	io.stdout:write("\n")

	collectgarbage('collect')
	bench_choice_two_channels("op1 choice(getA,getB)", make_chan1, op1.perform_raw, op1.choice)

	collectgarbage('collect')
	bench_choice_two_channels("op2 choice(getA,getB)", make_chan2, op2.perform, op2.choice)

	io.stdout:write("------------------------------------------------------------\n")
	runtime.stop()
end)

runtime.main()

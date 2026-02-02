-- tests/bench_channel_vs_channel2.lua
--
-- Benchmark: 1e5 rendezvous sends using channel (op1) vs channel2 (op2).
--
-- Run:
--   luajit tests/bench_channel_vs_channel2.lua
--   luajit tests/bench_channel_vs_channel2.lua 200000   -- override N
--
-- Notes:
--   * single-threaded cooperative scheduler
--   * unbuffered rendezvous channels
--   * measures elapsed scheduler monotonic time via runtime.now()

package.path = '../src/?.lua;' .. package.path

local runtime  = require 'fibers.runtime'

local op   = require 'fibers.op'
local chan = require 'fibers.channel'

local op3   = require 'fibers.op2'
local chan3 = require 'fibers.channel2'

local tonumber = tonumber
local format   = string.format

local N = tonumber(arg and arg[1]) or 100000

local function drain_scheduler(steps)
  for _ = 1, (steps or 20) do runtime.yield() end
end

local function bench(label, make_channel, perform_fn)
  -- Data channel + completion channels
  local ch        = make_channel()
  local done_recv = make_channel()
  local done_send = make_channel()

  -- Receiver: consume N messages, then signal done.
  runtime.spawn_raw(function ()
    for _ = 1, N do
      perform_fn(ch:get_op())
    end
    perform_fn(done_recv:put_op(true))
  end)

  -- Sender: send N messages, then signal done.
  runtime.spawn_raw(function ()
    -- send a constant to reduce allocation noise
    for _ = 1, N do
      perform_fn(ch:put_op(1))
    end
    perform_fn(done_send:put_op(true))
  end)

  local t0 = runtime.now()

  -- Wait for both to finish.
  perform_fn(done_recv:get_op())
  perform_fn(done_send:get_op())

  local t1 = runtime.now()
  local dt = t1 - t0

  -- Give the scheduler a moment to run any last queued tasks.
  drain_scheduler(10)

  local mps = (dt > 0) and (N / dt) or math.huge
  io.stdout:write(format("%-24s  N=%d  time=%.6fs  rate=%.0f msg/s\n", label, N, dt, mps))

  return dt, mps
end

runtime.spawn_raw(function ()
  io.stdout:write(format("Benchmark: %d rendezvous sends\n", N))
  io.stdout:write("------------------------------------------------------------\n")

  -- Warm-up (keeps first-run effects out of the main numbers).
  bench("warm-up (channel)", function () return chan.new() end, op.perform_raw)
  bench("warm-up (channel2)", function () return chan3.new() end, op3.perform)

  io.stdout:write("------------------------------------------------------------\n")

  local dt1, mps1 = bench("channel (op1)", function () return chan.new() end, op.perform_raw)
  local dt3, mps3 = bench("channel2 (op2)", function () return chan3.new(1) end, op3.perform)

  io.stdout:write("------------------------------------------------------------\n")
  if dt1 > 0 and dt3 > 0 then
    io.stdout:write(format("Relative: channel2 / channel = %.3fx time (lower is better)\n", dt3 / dt1))
    io.stdout:write(format("Relative: channel2 / channel = %.3fx rate (higher is better)\n", mps3 / mps1))
  end

  runtime.stop()
end)

runtime.main()

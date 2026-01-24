-- bench_channel_vs_channel2.lua
--
-- Microbenchmark: channel.lua (op) vs channel2.lua (op2)
-- Uses only: runtime, op/op2, channel/channel2, fibers.utils.time
--
-- Run (example):
--   lua bench_channel_vs_channel2.lua
--
-- Adjust N/RUNS as needed.

local runtime = require 'fibers.runtime'
local time    = require 'fibers.utils.time'
local op      = require 'fibers.op'
local op2     = require 'fibers.op2'

-- channel.lua depends on fibers.performer in your earlier version.
-- If higher layers are not ported, provide a tiny stub that just calls op.perform_raw.
-- (We do not use Channel:put()/get(); only *_op plus perform functions.)
if not package.preload['fibers.performer'] then
  package.preload['fibers.performer'] = function ()
    local op_ = require 'fibers.op'
    return { perform = op_.perform_raw }
  end
end

local channel  = require 'fibers.channel'
local channel2 = require 'fibers.channel2'

-- Simple join for two worker fibres without waitgroups/scopes.
local function run_two_workers(worker_a, worker_b)
  local join_sched, join_fib
  local remaining = 2

  local function done()
    remaining = remaining - 1
    if remaining == 0 then
      join_sched:schedule(join_fib)
    end
  end

  runtime.spawn_raw(function ()
    worker_a()
    done()
  end)

  runtime.spawn_raw(function ()
    worker_b()
    done()
  end)

  -- Suspend until both workers schedule us runnable again.
  runtime.suspend(function (sched, fib)
    join_sched = sched
    join_fib   = fib
  end)
end

local function format_ns_per(x)
  -- x is seconds; render as ns
  return string.format('%.1f', x * 1e9)
end

local function format_mops(x)
  -- x is ops/sec
  return string.format('%.2f', x / 1e6)
end

-- Ping–pong benchmark: two channels:
--   f1: put on a, get from b
--   f2: get from a, put on b
--
-- For N iterations:
--   rendezvous = 2N
--   op calls   = 4N
local function bench_op_channel(N)
  local a = channel.new(0) -- unbuffered
  local b = channel.new(0)

  local sum = 0

  local function f1()
    for i = 1, N do
      op.perform_raw(a:put_op(i))
      local v = op.perform_raw(b:get_op())
      -- Use the value to discourage accidental dead-code effects.
      if v ~= nil then sum = sum + v end
    end
  end

  local function f2()
    for _ = 1, N do
      local v = op.perform_raw(a:get_op())
      op.perform_raw(b:put_op(v))
    end
  end

  local t0 = time.monotonic()
  run_two_workers(f1, f2)
  local t1 = time.monotonic()

  return (t1 - t0), sum
end

local function bench_op2_channel(N)
  local a = channel2.new() -- unbuffered rendezvous by design
  local b = channel2.new()

  local sum = 0

  local function f1()
    for i = 1, N do
      op2.perform(a:put_op(i))
      local v = op2.perform(b:get_op())
      if v ~= nil then sum = sum + v end
    end
  end

  local function f2()
    for _ = 1, N do
      local v = op2.perform(a:get_op())
      op2.perform(b:put_op(v))
    end
  end

  local t0 = time.monotonic()
  run_two_workers(f1, f2)
  local t1 = time.monotonic()

  return (t1 - t0), sum
end

local function best_of(runs)
  local best = nil
  for i = 1, #runs do
    local v = runs[i]
    if v and (best == nil or v < best) then best = v end
  end
  return best
end

local function run_suite(label, fn, N, RUNS, WARMUP)
  -- Warm-up (best-effort, to settle caches/GC effects)
  if WARMUP and WARMUP > 0 then
    fn(WARMUP)
  end

  collectgarbage()

  local times = {}
  local last_sum = 0

  for r = 1, RUNS do
    collectgarbage()
    local dt, sum = fn(N)
    times[#times + 1] = dt
    last_sum = sum
  end

  local best = best_of(times)

  local rendezvous = 2 * N
  local op_calls   = 4 * N

  local per_rdv = best / rendezvous
  local per_op  = best / op_calls

  local rdv_per_s = rendezvous / best
  local ops_per_s = op_calls / best

  print(('== %s =='):format(label))
  print(('N=%d, runs=%d (best-of), elapsed=%.6fs'):format(N, RUNS, best))
  print(('ns per rendezvous: %s'):format(format_ns_per(per_rdv)))
  print(('ns per op-call   : %s'):format(format_ns_per(per_op)))
  print(('rendezvous/s     : %s M'):format(format_mops(rdv_per_s)))
  print(('op-calls/s       : %s M'):format(format_mops(ops_per_s)))
  print(('checksum         : %d'):format(last_sum))
  print('')
end

-- Parameters
local N      = tonumber(os.getenv('N') or '') or 200000
local RUNS   = tonumber(os.getenv('RUNS') or '') or 5
local WARMUP = tonumber(os.getenv('WARMUP') or '') or 20000

local results = {}

runtime.spawn_raw(function ()
  run_suite('channel.lua + op.perform_raw',  bench_op_channel,  N, RUNS, WARMUP)
  run_suite('channel2.lua + op2.perform',    bench_op2_channel, N, RUNS, WARMUP)

  runtime.stop()
end)

runtime.main()

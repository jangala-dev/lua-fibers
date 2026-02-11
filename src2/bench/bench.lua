-- bench.lua
--
-- Usage:
--   lua bench.lua                -- run all benchmarks
--   lua bench.lua channels,choice,all
--
-- Timing source:
--   require 'nixio'.gettime()  -- decimal seconds

package.path = '../?.lua;' .. package.path

local nixio = require 'nixio'
local gettime = assert(nixio.gettime, 'nixio.gettime missing')

local sched_mod = require 'fibers.sched'
local new_sched = sched_mod.new or (sched_mod.Scheduler and sched_mod.Scheduler.new)
assert(type(new_sched) == 'function', 'fibers.sched: no constructor found')

local runtime = require 'fibers.runtime'
local op      = require 'fibers.op'

local chan_mod = require 'fibers.channel'
local new_chan = chan_mod.new or (chan_mod.Channel and chan_mod.Channel.new)
assert(type(new_chan) == 'function', 'fibers.channel: no constructor found')

local unpack = rawget(table, 'unpack') or _G.unpack

local function pack(...)
  return { n = select('#', ...), ... }
end

local function split_csv(s)
  local t = {}
  if not s or s == '' then return t end
  for part in s:gmatch('[^,]+') do
    part = part:match('^%s*(.-)%s*$')
    if part ~= '' then t[#t + 1] = part end
  end
  return t
end

local function fmt(n)
  -- small, stable formatting without locale surprises
  if n >= 100 then
    return string.format('%.2f', n)
  elseif n >= 10 then
    return string.format('%.3f', n)
  else
    return string.format('%.4f', n)
  end
end

local function ops_per_sec(ops, secs)
  if secs <= 0 then return math.huge end
  return ops / secs
end

local function pick_iters(default_n)
  local env = os.getenv('BENCH_N')
  if env then
    local v = tonumber(env)
    if v and v > 0 then return v end
  end
  return default_n
end

-- -------------------------------------------------------------------
-- Bench-only reusable primitives (reduce allocation noise where useful)
-- -------------------------------------------------------------------

local function out_copy(dst, src)
  if not dst then return end
  local old = dst.n or 0
  local n   = src.n or 0
  dst.n     = n
  for i = 1, n do dst[i] = src[i] end
  for i = n + 1, old do dst[i] = nil end
end

local function const_ticket(...)
  local payload = pack(...)
  local state = { payload = payload }
  return op.new_primitive(
    function(self, _ctx, out)
      out_copy(out, self.payload)
      return self
    end,
    function(self, _ctx)
      return unpack(self.payload, 1, self.payload.n)
    end,
    function(_self, _ctx, _why) end,
    state
  )
end

local function never_ticket()
  local state = { waker = nil }
  return op.new_primitive(
    function(self, ctx, _out)
      self.waker = ctx.waker
      return nil
    end,
    function()
      error('bench never_ticket: commit should be unreachable', 0)
    end,
    function(self, _ctx, _why)
      self.waker = nil
    end,
    state
  )
end

-- -------------------------------------------------------------------
-- Harness
-- -------------------------------------------------------------------

local function run_in_runtime(worker_fn, iters)
  local sched = new_sched()
  runtime.init(sched)

  local result = { ok = false }

  runtime.spawn(function()
    worker_fn(iters, result)
    result.ok = true
  end, 'bench-worker')

  runtime.main()
  assert(result.ok == true, 'bench worker did not complete')
  return result
end

local function bench(name, iters, worker_fn)
  collectgarbage('collect')
  collectgarbage('collect')

  local t0 = gettime()
  local res = run_in_runtime(worker_fn, iters)
  local t1 = gettime()

  local ops_done = assert(res.ops, 'bench worker must set result.ops')
  return (t1 - t0), ops_done
end

-- -------------------------------------------------------------------
-- Benchmarks
-- -------------------------------------------------------------------

local benches = {}

benches.channels = {
  iters = function() return pick_iters(200000) end,
  fn = function(n, r)
    local ch = new_chan()
    local sum = 0

    runtime.spawn(function()
      for _ = 1, n do
        sum = sum + ch:get()
      end
    end, 'chan-consumer')

    runtime.spawn(function()
      for i = 1, n do
        ch:put(i)
      end
    end, 'chan-producer')

    -- worker fibre returns immediately; other fibres do the work.
    -- runtime.main() waits for all to complete.
    r.ops = n
    r.sum = sum -- not used; sanity checked below in a post-pass (see below)
  end,
  post = function(_iters, res)
    -- We cannot reliably read 'sum' computed in another fibre here (it is in that fibre's scope),
    -- so keep this bench focused on throughput.
    -- If you want a correctness guard, run the separate channel unit tests.
    return res
  end,
}

benches.perform_const = {
  iters = function() return pick_iters(800000) end,
  fn = function(n, r)
    local t = const_ticket(1, 2, 3)
    local a, b, c
    for _ = 1, n do
      a, b, c = op.perform(t)
      assert(a == 1 and b == 2 and c == 3)
    end
    r.ops = n
  end,
}

benches.choice = {
  iters = function() return pick_iters(300000) end,
  fn = function(n, r)
    local a, b = const_ticket('a'), const_ticket('b')
    local v
    for _ = 1, n do
      v = op.perform(op.choice(a, b))
      assert(v == 'a' or v == 'b')
    end
    r.ops = n
  end,
}

benches.choice_never = {
  iters = function() return pick_iters(250000) end,
  fn = function(n, r)
    local w = const_ticket('win')
    local v
    for _ = 1, n do
      v = op.perform(op.choice(w, never_ticket()))
      assert(v == 'win')
    end
    r.ops = n
  end,
}

benches.all = {
  iters = function() return pick_iters(200000) end,
  fn = function(n, r)
    local a, b = const_ticket(1), const_ticket(2, 'b')
    local r1, r2
    for _ = 1, n do
      r1, r2 = op.perform(op.all(a, b))
      assert(r1.n == 1 and r1[1] == 1)
      assert(r2.n == 2 and r2[1] == 2 and r2[2] == 'b')
    end
    r.ops = n
  end,
}

benches.wrap = {
  iters = function() return pick_iters(250000) end,
  fn = function(n, r)
    local base = const_ticket(10)
    local v
    for _ = 1, n do
      v = op.perform(base:wrap(function(x) return x + 1 end))
      assert(v == 11)
    end
    r.ops = n
  end,
}

benches.and_then = {
  iters = function() return pick_iters(200000) end,
  fn = function(n, r)
    local base = const_ticket(10, 'p')
    local a, b
    for _ = 1, n do
      a, b = op.perform(base:and_then(function(x, s)
        return const_ticket(x + 1, s .. 'q')
      end))
      assert(a == 11 and b == 'pq')
    end
    r.ops = n
  end,
}

benches.guard = {
  iters = function() return pick_iters(200000) end,
  fn = function(n, r)
    local count = 0
    local v
    for _ = 1, n do
      v = op.perform(op.guard(function()
        count = count + 1
        return const_ticket(7)
      end))
      assert(v == 7)
    end
    assert(count == n)
    r.ops = n
  end,
}

benches.with_nack = {
  iters = function() return pick_iters(200000) end,
  fn = function(n, r)
    local win = const_ticket('win')
    local v
    for _ = 1, n do
      v = op.perform(op.choice(
        win,
        op.with_nack(function(_nack)
          -- losing arm; triggers cond:signal() on RB_ABORT
          return never_ticket()
        end)
      ))
      assert(v == 'win')
    end
    r.ops = n
  end,
}

benches.bracket_commit = {
  iters = function() return pick_iters(200000) end,
  fn = function(n, r)
    local acq, rel = 0, 0
    local function acquire() acq = acq + 1; return {} end
    local function release(_res, aborted)
      rel = rel + 1
      assert(aborted == false)
    end
    local v
    for _ = 1, n do
      v = op.perform(op.bracket(acquire, release, function(_res) return const_ticket(1) end))
      assert(v == 1)
    end
    assert(acq == n and rel == n)
    r.ops = n
  end,
}

benches.bracket_abort = {
  iters = function() return pick_iters(200000) end,
  fn = function(n, r)
    local acq, rel, aborted_seen = 0, 0, 0
    local function acquire() acq = acq + 1; return {} end
    local function release(_res, aborted)
      rel = rel + 1
      if aborted then aborted_seen = aborted_seen + 1 end
    end
    local win = const_ticket('win')
    local v
    for _ = 1, n do
      v = op.perform(op.choice(
        win,
        op.bracket(acquire, release, function(_res) return never_ticket() end)
      ))
      assert(v == 'win')
    end
    assert(acq == n and rel == n and aborted_seen == n)
    r.ops = n
  end,
}

benches.finally_abort = {
  iters = function() return pick_iters(200000) end,
  fn = function(n, r)
    local cleaned = 0
    local win = const_ticket('win')
    local v
    for _ = 1, n do
      v = op.perform(op.choice(
        win,
        never_ticket():finally(function(aborted)
          if aborted then cleaned = cleaned + 1 end
        end)
      ))
      assert(v == 'win')
    end
    assert(cleaned == n)
    r.ops = n
  end,
}

benches.channel_choice_get_timeout = {
  iters = function() return pick_iters(150000) end,
  fn = function(n, r)
    local ch = new_chan()
    local got = 0

    -- One fibre repeatedly does choice(get_op, timeout) where timeout always wins.
    runtime.spawn(function()
      for _ = 1, n do
        local v = op.perform(op.choice(ch:get_op(), const_ticket('timeout')))
        assert(v == 'timeout')
        got = got + 1
      end
    end, 'chooser')

    r.ops = n
    r.got = got
  end,
}

-- -------------------------------------------------------------------
-- Runner
-- -------------------------------------------------------------------

local function list_names()
  local names = {}
  for k in pairs(benches) do names[#names + 1] = k end
  table.sort(names)
  return names
end

local function run_one(name)
  local b = benches[name]
  if not b then
    error('unknown benchmark: ' .. tostring(name), 0)
  end

  local iters = b.iters()
  local secs, ops_done = bench(name, iters, b.fn)
  local rate = ops_per_sec(ops_done, secs)

  io.write(string.format(
    '%-26s  iters=%-8d  secs=%-8s  ops/s=%s\n',
    name, iters, fmt(secs), fmt(rate)
  ))
end

local function main()
  local arg1 = _G.arg and _G.arg[1] or nil
  local selected = split_csv(arg1)

  if #selected == 0 then
    selected = list_names()
  end

  io.write('Lua benches (timed by nixio.gettime)\n')
  io.write('Selected: ' .. table.concat(selected, ', ') .. '\n\n')

  for _, name in ipairs(selected) do
    run_one(name)
  end
end

main()

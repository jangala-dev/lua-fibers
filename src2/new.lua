-- op_fibres_poll.lua
--
-- Transactional ops for cooperative fibres (Lua 5.1 friendly).
--
-- Core model
--   * A fibre may only block by yielding a Pulse.
--   * A ticket is a small state machine implementing:
--       poll(ctx)   -> self | nil, pulse
--       commit(ctx) -> ...results...   (must not yield)
--       abort(ctx)  -> nil            (idempotent best-effort cleanup)
--   * perform(ticket, ctx) is the only waiting point.
--
-- Contract (intentional discipline; no “safety net” latching)
--   * Pulses are edge-triggered wake hints for current waiters only.
--     Signals may be dropped when no waiters are subscribed.
--   * poll(ctx) must be non-blocking. If it cannot complete, it must return a
--     non-nil pulse that will be signalled by some other runnable activity.
--   * commit(ctx) must not yield and should be guarded against double execution.
--   * abort(ctx) must be safe to call more than once, and must unregister the
--     ticket from any wait structures promptly.
--   * No callbacks or re-entrancy are assumed: progress happens only when the
--     scheduler runs tasks/fibres.

local nixio = require 'nixio'

local unpack = rawget(table, 'unpack') or _G.unpack

local function pack(...)
  return { n = select('#', ...), ... }
end

----------------------------------------------------------------------
-- Debug switch (cheap when false)
----------------------------------------------------------------------

local DEBUG = false

local function dcheck(cond, msg, level)
  if DEBUG and not cond then
    error(msg, (level or 1) + 1)
  end
end

----------------------------------------------------------------------
-- Scheduler (cooperative, idempotent schedule)
----------------------------------------------------------------------

local Scheduler = {}
Scheduler.__index = Scheduler

function Scheduler.new()
  return setmetatable({ q = {}, head = 1, tail = 0 }, Scheduler)
end

function Scheduler:schedule(task)
  -- Idempotent enqueue. Assumes task has a :run(sched) method.
  if task._queued then return end
  task._queued = true
  self.tail = self.tail + 1
  self.q[self.tail] = task
end

function Scheduler:step()
  if self.head > self.tail then
    return false
  end

  local t = self.q[self.head]
  self.q[self.head] = nil
  self.head = self.head + 1

  t._queued = false
  t:run(self)

  if self.head > self.tail then
    self.head, self.tail = 1, 0
  end
  return true
end

----------------------------------------------------------------------
-- Pulse (single wait/wake mechanism; edge-triggered)
----------------------------------------------------------------------

local Pulse = {}
Pulse.__index = Pulse

function Pulse.new(sched)
  return setmetatable({ sched = sched, waiters = {}, nwait = 0 }, Pulse)
end

function Pulse:signal_if_waiting()
  if self.nwait == 0 then return end
  return self:signal()
end

function Pulse:signal()
  local n = self.nwait
  if n == 0 then return end

  local ws = self.waiters
  self.nwait = 0

  for i = 1, n do
    local fib = ws[i]
    ws[i] = nil
    if fib._waiting_pulse == self then
      fib._waiting_pulse = nil
      self.sched:schedule(fib)
    end
  end
end

function Pulse:subscribe(fib)
  -- De-dupe.
  if fib._waiting_pulse == self then
    return
  end
  -- Teaching/discipline invariant: one wait at a time.
  if fib._waiting_pulse ~= nil then
    error('fibre attempted to wait on two pulses', 0)
  end

  fib._waiting_pulse = self
  local n = self.nwait + 1
  self.nwait = n
  self.waiters[n] = fib
end

----------------------------------------------------------------------
-- Runtime (fibres + only-yield-Pulse)
----------------------------------------------------------------------

local runtime = {
  sched    = nil,
  progress = nil,  -- optional coalescing pulse for composites
  _current = nil,
  _live    = {},
}

local function await(pulse)
  return coroutine.yield(pulse)
end

local Fiber = {}
Fiber.__index = Fiber

function Fiber.new(fn, name)
  return setmetatable({
    co = coroutine.create(fn),
    name = name or '<fibre>',
    _queued = false,
    _waiting_pulse = nil,
  }, Fiber)
end

function Fiber:run(_sched)
  local saved = runtime._current
  runtime._current = self

  local ok, yielded = coroutine.resume(self.co)

  runtime._current = saved

  if not ok then
    runtime._live[self] = nil
    error(('fibre %s crashed: %s'):format(self.name, tostring(yielded)), 0)
  end

  if coroutine.status(self.co) == 'dead' then
    runtime._live[self] = nil
    return
  end

  -- Blessed protocol: yield must be a Pulse.
  if type(yielded) == 'table' and getmetatable(yielded) == Pulse then
    yielded:subscribe(self)
    return
  end

  runtime._live[self] = nil
  error(('fibre %s yielded unexpected value'):format(self.name), 0)
end

local function init(sched)
  if type(sched) ~= 'table' then error('runtime.init expects a Scheduler', 2) end
  runtime.sched = sched
  runtime.progress = Pulse.new(sched)
  runtime._current = nil
  runtime._live = {}
end

local function spawn(fn, name)
  if not runtime.sched then error('runtime not initialised (call init(sched))', 2) end
  local f = Fiber.new(fn, name)
  runtime._live[f] = true
  runtime.sched:schedule(f)
  return f
end

local function main()
  if not runtime.sched then error('runtime not initialised (call init(sched))', 2) end
  while runtime.sched:step() do end
  if next(runtime._live) then
    error('deadlock: no runnable tasks (all fibres appear to be waiting)', 0)
  end
end

----------------------------------------------------------------------
-- Transactional ops: poll/commit/abort
----------------------------------------------------------------------

local function perform(ticket, ctx)
  dcheck(type(ctx) == 'table', 'perform expects ctx to be a table', 2)

  while true do
    local cap, pulse = ticket:poll(ctx)
    if cap then
      return cap:commit(ctx)
    end
    if pulse == nil then
      error('ticket:poll returned no capability and no pulse', 0)
    end
    dcheck(getmetatable(pulse) == Pulse, 'ticket:poll returned a non-Pulse wait object', 2)
    await(pulse)
  end
end

-- always(...)
local Always = {}
Always.__index = Always

function Always.new(...)
  return setmetatable({ done = false, payload = pack(...) }, Always)
end

function Always:poll(_ctx)
  return self
end

function Always:commit(_ctx)
  -- Idempotent: safe to call twice (returns same values), but intended single-shot.
  self.done = true
  return unpack(self.payload, 1, self.payload.n)
end

function Always:abort(_ctx)
  self.done = true
end

-- never()
local Never = {}
Never.__index = Never

function Never.new(sched)
  return setmetatable({ pulse = Pulse.new(sched) }, Never)
end

function Never:poll(_ctx)
  return nil, self.pulse
end

function Never:commit(_ctx)
  return nil
end

function Never:abort(_ctx)
end

-- map(inner, f)
local Map = {}
Map.__index = Map

local function map(inner, f)
  if type(f) ~= 'function' then error('map expects a function', 2) end
  return setmetatable({ inner = inner, f = f, cap = nil, done = false }, Map)
end

function Map:poll(ctx)
  if self.done then return self end

  local cap, pulse = self.inner:poll(ctx)
  if cap then
    self.cap = cap
    return self
  end
  return nil, pulse
end

function Map:commit(ctx)
  if self.done then return end
  self.done = true
  -- Multiple returns flow through directly; no pack/unpack.
  return self.f(self.cap:commit(ctx))
end

function Map:abort(ctx)
  if self.done then return end
  self.done = true
  if self.cap then
    self.cap:abort(ctx)
    self.cap = nil
  else
    self.inner:abort(ctx)
  end
end

-- choice(...)
local Choice = {}
Choice.__index = Choice

-- Shared helper: abort losers and return committed values (no per-call closure).
local function abort_losers_and_return(self, wi, ctx, ...)
  for i = 1, self.n do
    if i ~= wi then
      self.ops[i]:abort(ctx)
    end
  end
  return ...
end

local function choice(...)
  local ops = { ... }
  if #ops == 0 then error('choice expects at least one op', 2) end
  if #ops == 1 then return ops[1] end

  return setmetatable({
    ops      = ops,
    n        = #ops,
    rr       = 1,
    done     = false,
    winner_i = nil,
    cap      = nil,
    sel      = { winner = nil }, -- selection capability passed via ctx.select
  }, Choice)
end

function Choice:poll(ctx)
  if self.done then return self end
  if self.cap then return self end

  dcheck(runtime.progress ~= nil, 'choice requires runtime.progress (call init)', 2)

  local prev_sel = ctx.select
  ctx.select = self.sel

  local n = self.n
  local start = self.rr
  self.rr = (self.rr % n) + 1

  for k = 0, n - 1 do
    local i = ((start + k - 1) % n) + 1
    local cap = self.ops[i]:poll(ctx)
    if cap then
      self.winner_i = i
      self.cap = cap
      ctx.select = prev_sel
      return self
    end
  end

  ctx.select = prev_sel
  return nil, runtime.progress
end

function Choice:commit(ctx)
  if self.done then return end
  self.done = true

  local wi = assert(self.winner_i, 'choice.commit: no winner')
  local out = abort_losers_and_return(self, wi, ctx, self.cap:commit(ctx))

  -- Drop selection references promptly.
  self.sel.winner = nil
  self.cap = nil

  return out
end

function Choice:abort(ctx)
  if self.done then return end
  self.done = true
  for i = 1, self.n do
    self.ops[i]:abort(ctx)
  end
  self.sel.winner = nil
  self.cap = nil
end

-- all(...)
local All = {}
All.__index = All

local function all(...)
  local ops = { ... }
  if #ops == 0 then error('all expects at least one op', 2) end
  if #ops == 1 then return ops[1] end

  return setmetatable({
    ops  = ops,
    n    = #ops,
    done = false,
    caps = nil, -- prepared caps
  }, All)
end

function All:poll(ctx)
  if self.done then return self end
  if self.caps then return self end

  dcheck(runtime.progress ~= nil, 'all requires runtime.progress (call init)', 2)

  local caps = {}
  for i = 1, self.n do
    local cap, _pulse = self.ops[i]:poll(ctx)
    if not cap then
      -- Abort only those already prepared (dense prefix), avoiding Lua 5.1 #table pitfalls.
      for j = 1, i - 1 do
        caps[j]:abort(ctx)
      end
      return nil, runtime.progress
    end
    caps[i] = cap
  end

  self.caps = caps
  return self
end

function All:commit(ctx)
  if self.done then return end
  self.done = true

  -- One allocation, no second copy table.
  local out = { n = self.n }
  for i = 1, self.n do
    out[i] = self.caps[i]:commit(ctx) -- first return only, by design
  end

  -- Drop references promptly.
  self.caps = nil

  return unpack(out, 1, out.n)
end

function All:abort(ctx)
  if self.done then return end
  self.done = true
  for i = 1, self.n do
    self.ops[i]:abort(ctx)
  end
  self.caps = nil
end

----------------------------------------------------------------------
-- Unbuffered channel as transactional tickets
----------------------------------------------------------------------

local Channel = {}
Channel.__index = Channel

function Channel.new(sched)
  return setmetatable({
    pulse = Pulse.new(sched),
    put_h = nil, put_t = nil,
    get_h = nil, get_t = nil,
  }, Channel)
end

function Channel:_signal()
  self.pulse:signal_if_waiting()
  if runtime.progress then
    runtime.progress:signal_if_waiting()
  end
end

-- intrusive queue ops (ticket is its own node)
local function unlink(ch, kind, n)
  if not n.inq then return end
  local prev, next = n.prev, n.next

  if kind == 'put' then
    if prev then prev.next = next else ch.put_h = next end
    if next then next.prev = prev else ch.put_t = prev end
  else
    if prev then prev.next = next else ch.get_h = next end
    if next then next.prev = prev else ch.get_t = prev end
  end

  n.prev, n.next = nil, nil
  n.inq = false
end

local function push(ch, kind, n)
  if n.inq then return end

  if kind == 'put' then
    n.prev = ch.put_t
    n.next = nil
    n.inq  = true
    if ch.put_t then ch.put_t.next = n else ch.put_h = n end
    ch.put_t = n
  else
    n.prev = ch.get_t
    n.next = nil
    n.inq  = true
    if ch.get_t then ch.get_t.next = n else ch.get_h = n end
    ch.get_t = n
  end
end

local function find_unmatched_put(head)
  local n = head
  while n do
    if (not n.done) and (n.peer == nil) then return n end
    n = n.next
  end
  return nil
end

local function find_eligible_get(head)
  local n = head
  while n do
    if (not n.done) and (n.peer == nil) then
      local sel = n.sel
      if not sel then return n end
      local w = sel.winner
      if (w == nil) or (w == n) then return n end
    end
    n = n.next
  end
  return nil
end

local function detach_uncommitted(ch, a, b)
  if a.peer == b then a.peer = nil end
  if b.peer == a then b.peer = nil end
  ch:_signal()
end

local function commit_pair(ch, putop, getop)
  if putop.done or getop.done then return end

  putop.done = true
  getop.done = true
  getop.result = putop.val

  unlink(ch, 'put', putop)
  unlink(ch, 'get', getop)

  putop.peer = nil
  getop.peer = nil

  -- Drop select reference on get side promptly.
  getop.sel = nil

  ch:_signal()
end

-- Put ticket
local Put = {}
Put.__index = Put

function Channel:put_op(val)
  return setmetatable({
    ch   = self,
    val  = val,
    peer = nil,
    done = false,
    prev = nil, next = nil, inq = false,
  }, Put)
end

function Put:poll(_ctx)
  local ch = self.ch
  if self.done then return self end

  local g = self.peer
  if g then
    local sel = g.sel
    if sel and sel.winner ~= g then
      return nil, ch.pulse
    end
    if sel and sel.winner == nil then
      return nil, ch.pulse
    end
    return self
  end

  local r = find_eligible_get(ch.get_h)
  if r then
    self.peer = r
    r.peer = self
    ch:_signal()

    local sel = r.sel
    if sel and sel.winner == nil then
      return nil, ch.pulse
    end
    return self
  end

  push(ch, 'put', self)
  return nil, ch.pulse
end

function Put:commit(_ctx)
  if self.done then return end
  local g = self.peer
  if g then
    commit_pair(self.ch, self, g)
  end
end

function Put:abort(_ctx)
  if self.done then return end
  local ch = self.ch
  local g = self.peer
  if g and (not g.done) then
    detach_uncommitted(ch, self, g)
  end
  self.peer = nil
  unlink(ch, 'put', self)
end

-- Get ticket
local Get = {}
Get.__index = Get

function Channel:get_op()
  return setmetatable({
    ch     = self,
    peer   = nil,
    result = nil,
    done   = false,
    sel    = nil,
    prev   = nil, next = nil, inq = false,
  }, Get)
end

function Get:poll(ctx)
  local ch = self.ch
  if self.done then return self end

  self.sel = ctx.select

  local p = self.peer
  if p then
    local sel = self.sel
    if sel and sel.winner == nil then
      sel.winner = self
      ch:_signal()
    end
    if sel and sel.winner ~= self then
      return nil, ch.pulse
    end
    return self
  end

  local s = find_unmatched_put(ch.put_h)
  if s then
    self.peer = s
    s.peer = self

    local sel = self.sel
    if sel and sel.winner == nil then
      sel.winner = self
    end

    ch:_signal()

    if sel and sel.winner ~= self then
      return nil, ch.pulse
    end
    return self
  end

  push(ch, 'get', self)
  return nil, ch.pulse
end

function Get:commit(_ctx)
  if self.done then return self.result end
  local p = self.peer
  if p then
    commit_pair(self.ch, p, self)
  end
  return self.result
end

function Get:abort(_ctx)
  if self.done then return end
  local ch = self.ch
  local p = self.peer
  if p and (not p.done) then
    detach_uncommitted(ch, p, self)
  end
  self.peer = nil
  self.sel = nil
  unlink(ch, 'get', self)
end

-- Convenience
function Channel:put(v, ctx) return perform(self:put_op(v), ctx) end
function Channel:get(ctx)    return perform(self:get_op(), ctx) end

----------------------------------------------------------------------
-- Benchmarks (use nixio.gettime(): seconds as double)
----------------------------------------------------------------------

local function bench_run_until_idle()
  while runtime.sched:step() do end
  if next(runtime._live) then
    error('deadlock during benchmark (fibres still live but no runnable tasks)', 0)
  end
end

local function bench_channel_rendezvous(N)
  runtime.sched    = Scheduler.new()
  runtime.progress = Pulse.new(runtime.sched)
  runtime._live    = {}
  runtime._current = nil

  local ctx = { select = nil }
  local ch  = Channel.new(runtime.sched)

  local sum = 0

  spawn(function()
    for i = 1, N do
      ch:put(i, ctx)
    end
  end, 'bench_put')

  spawn(function()
    for _ = 1, N do
      sum = sum + (ch:get(ctx) or 0)
    end
  end, 'bench_get')

  collectgarbage('collect')
  local t0 = nixio.gettime()
  bench_run_until_idle()
  local t1 = nixio.gettime()

  local dt = t1 - t0
  io.write(('[bench] channel rendezvous: N=%d; time=%.6f s; throughput=%.0f pairs/s; checksum=%d\n')
    :format(N, dt, N / dt, sum))
end

local function bench_choice_alternating(N)
  runtime.sched    = Scheduler.new()
  runtime.progress = Pulse.new(runtime.sched)
  runtime._live    = {}
  runtime._current = nil

  local ctx = { select = nil }
  local a   = Channel.new(runtime.sched)
  local b   = Channel.new(runtime.sched)

  local sum = 0

  -- Single sender alternates puts between channels.
  spawn(function()
    for i = 1, N do
      if (i % 2) == 1 then
        a:put(i, ctx)
      else
        b:put(i, ctx)
      end
    end
  end, 'bench_sender')

  -- Single receiver uses choice(get(a), get(b)).
  spawn(function()
    for _ = 1, N do
      local v = perform(choice(a:get_op(), b:get_op()), ctx)
      sum = sum + (v or 0)
    end
  end, 'bench_choice_recv')

  collectgarbage('collect')
  local t0 = nixio.gettime()
  bench_run_until_idle()
  local t1 = nixio.gettime()

  local dt = t1 - t0
  io.write(('[bench] choice(alternating): N=%d; time=%.6f s; throughput=%.0f ops/s; checksum=%d\n')
    :format(N, dt, N / dt, sum))
end

-- Run the demo, then benchmarks.
-- You can override N via argv[1], e.g. `lua op_fibres_demo.lua 200000`.
local N = tonumber(arg and arg[1]) or 200000

io.write(('\n[bench] starting (N=%d)\n'):format(N))
bench_channel_rendezvous(N)
bench_choice_alternating(N)

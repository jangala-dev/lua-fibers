--=============================================================================
-- Design invariants (read before modifying)
--=============================================================================
--
-- This runtime is:
--   * Single-threaded and cooperative: fibres run until they yield explicitly.
--   * Enqueue-only: wake-ups schedule fibres onto the Scheduler queue; there is
--     no inline resume, no nested scheduler stepping, and no re-entrancy into
--     other fibres from within poll/commit/rollback.
--   * Non-yielding commit: commit() must not yield. This guarantees that once a
--     ticket returns a cap to perform(), the subsequent commit executes
--     atomically with respect to other fibres.
--
-- Ticket API is internal:
--   * poll() is not a user-facing API. User code calls perform(ticket).
--   * perform() calls poll(ctx, nil) (no out buffer); out buffers exist for
--     internal combinators (choice/all/wrap/and_then).
--
-- Consequence:
--   * A cap cannot be invalidated "between poll returning cap and commit"
--     because nothing else can run in that interval.
--   * Invalidation is only observed across yields, by combinators validating
--     cached caps on the next poll.
--
-- Rollback reasons:
--   * rollback(ctx, RB_INVALID) means "drop cached cap due to invalidation".
--   * rollback(ctx, RB_ABORT)   means "abort this op (losing arm / cancellation)".
--=============================================================================

local nixio = require 'nixio'

local unpack = rawget(table, 'unpack') or _G.unpack

local function pack(...)
  return { n = select('#', ...), ... }
end

-- rollback reasons (internal)
local RB_ABORT   = 'rb_abort'
local RB_INVALID = 'rb_invalid'

----------------------------------------------------------------------
-- Prepared out-buffers (reusable tables)
----------------------------------------------------------------------

local function out_clear(out)
  if not out then return end
  local old = out.n or 0
  out.n = 0
  for i = 1, old do out[i] = nil end
end

local function out_copy(dst, src)
  if not dst then return end
  if dst == src then return end
  local old = dst.n or 0
  local n   = src.n or 0
  dst.n     = n
  for i = 1, n do
    dst[i] = src[i]
  end
  for i = n + 1, old do
    dst[i] = nil
  end
end

local function out_set1(out, v)
  if not out then return end
  local old = out.n or 0
  out.n = 1
  out[1] = v
  for i = 2, old do out[i] = nil end
end

local function out_capture(out, ...)
  if not out then return end
  local old = out.n or 0
  local n   = select('#', ...)
  out.n     = n
  for i = 1, n do
    out[i] = select(i, ...)
  end
  for i = n + 1, old do
    out[i] = nil
  end
end

----------------------------------------------------------------------
-- Scheduler (cooperative; idempotent enqueue)
----------------------------------------------------------------------

local Scheduler = {}
Scheduler.__index = Scheduler

function Scheduler.new()
  return setmetatable({ q = {}, head = 1, tail = 0 }, Scheduler)
end

-- Scheduler:schedule is intentionally idempotent.
function Scheduler:schedule(task)
  if task._queued then return end
  task._queued = true
  self.tail = self.tail + 1
  self.q[self.tail] = task
end

-- Scheduler:step runs exactly one task from the FIFO queue.
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
-- Pulse (per-fibre waker; one waiter; pending latch)
----------------------------------------------------------------------

local Pulse = {}
Pulse.__index = Pulse

function Pulse.new(sched)
  if not sched then error('Pulse.new requires a scheduler', 2) end
  return setmetatable({ sched = sched, waiter = nil, pending = false }, Pulse)
end

function Pulse:signal()
  local fib = self.waiter
  if not fib then
    self.pending = true
    return
  end

  fib._waiting_pulse = nil
  self.waiter = nil
  self.sched:schedule(fib)
end

function Pulse:subscribe(fib)
  if fib._waiting_pulse == self then
    return
  end

  if fib._waiting_pulse ~= nil then
    error('fibre attempted to wait on two pulses', 0)
  end

  if self.pending then
    self.pending = false
    self.sched:schedule(fib)
    return
  end

  fib._waiting_pulse = self
  self.waiter = fib
end

----------------------------------------------------------------------
-- Runtime (fibres + only-yield-Pulse + fibre-local ctx)
----------------------------------------------------------------------

local runtime = {
  sched    = nil,
  _current = nil,
  _live    = {},
}

local ctx_by_fibre = setmetatable({}, { __mode = 'k' })

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

function Fiber:run(_)
  local saved = runtime._current
  runtime._current = self

  local ok, yielded = coroutine.resume(self.co)

  runtime._current = saved

  if not ok then
    runtime._live[self] = nil
    ctx_by_fibre[self] = nil -- drop fibre-local ctx on crash
    error(('fibre %s crashed: %s'):format(self.name, tostring(yielded)), 0)
  end

  if coroutine.status(self.co) == 'dead' then
    runtime._live[self] = nil
    return
  end

  if type(yielded) ~= 'table' or type(yielded.subscribe) ~= 'function' then
    runtime._live[self] = nil
    error(('fibre %s yielded an invalid object (expected Pulse)'):format(self.name), 0)
  end

  yielded:subscribe(self)
end

local function init(sched)
  if type(sched) ~= 'table' then error('runtime.init expects a Scheduler', 2) end

  runtime.sched    = sched
  runtime._current = nil
  runtime._live    = {}

  ctx_by_fibre = setmetatable({}, { __mode = 'k' })
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

function runtime.ctx()
  local f = runtime._current
  if not f then error('runtime.ctx must be called from inside a fibre', 2) end

  local ctx = ctx_by_fibre[f]
  if not ctx then
    ctx = {
      in_perform = false,
      select_top = nil,
      waker      = Pulse.new(runtime.sched),
    }
    ctx_by_fibre[f] = ctx
  end
  return ctx
end

----------------------------------------------------------------------
-- Transactional tickets: poll/commit/rollback, with peer invalidation
----------------------------------------------------------------------

local function finish_perform(ctx, ...)
  ctx.in_perform = false
  return ...
end

local function perform(ticket)
  local ctx = runtime.ctx()

  if ctx.in_perform then
    error('perform is not re-entrant', 0)
  end
  ctx.in_perform = true

  local w = ctx.waker

  while true do
    local cap = ticket:poll(ctx, nil)
    if cap then
      return finish_perform(ctx, cap:commit(ctx))
    end

    ctx.in_perform = false
    coroutine.yield(w)
    ctx.in_perform = true
  end
end

----------------------------------------------------------------------
-- Op base + new_primitive + wrap + and_then (+ guard/with_nack/bracket/finally)
----------------------------------------------------------------------

local Wrap
local AndThen

local OpBase = {}

function OpBase:wrap(f)
  if type(f) ~= 'function' then error('wrap expects a function', 2) end
  return Wrap.new(self, f)
end

function OpBase:and_then(k)
  if type(k) ~= 'function' then error('and_then expects a function', 2) end
  return AndThen.new(self, k)
end

local function mixin_base(proto)
  for k, v in pairs(OpBase) do
    if proto[k] == nil then proto[k] = v end
  end
  return proto
end

local Primitive = {}
Primitive.__index = Primitive
mixin_base(Primitive)

function Primitive:poll(ctx, out) return self._poll(self, ctx, out) end
function Primitive:commit(ctx) return self._commit(self, ctx) end
function Primitive:rollback(ctx, why) return self._rollback(self, ctx, why) end

local function new_primitive(poll_fn, commit_fn, rollback_fn, state)
  if type(poll_fn) ~= 'function' then error('new_primitive: poll_fn must be a function', 2) end
  if type(commit_fn) ~= 'function' then error('new_primitive: commit_fn must be a function', 2) end
  if rollback_fn == nil then rollback_fn = function () end end
  if type(rollback_fn) ~= 'function' then error('new_primitive: rollback_fn must be a function or nil', 2) end

  local obj     = state or {}
  obj._poll     = poll_fn
  obj._commit   = commit_fn
  obj._rollback = rollback_fn
  return setmetatable(obj, Primitive)
end

----------------------------------------------------------------------
-- Wrap ticket
----------------------------------------------------------------------

Wrap = {}
Wrap.__index = Wrap
mixin_base(Wrap)

function Wrap.new(inner, f)
  return setmetatable({
    inner = inner,
    f     = f,

    cap       = nil,
    inner_buf = { n = 0 },
    prep      = { n = 0 },

    done = false,
  }, Wrap)
end

function Wrap:_clear(ctx, why)
  why = why or RB_ABORT
  if self.cap then
    self.cap:rollback(ctx, why)
    self.cap = nil
  else
    self.inner:rollback(ctx, why)
  end
  out_clear(self.inner_buf)
  out_clear(self.prep)
end

function Wrap:poll(ctx, out)
  if self.done then return self end

  -- 1) Validate cached cap once
  if self.cap then
    if not self.cap:poll(ctx, nil) then
      self:_clear(ctx, RB_INVALID)
    else
      out_copy(out, self.prep)
      return self
    end
  end

  -- 2) Acquire once
  local cap = self.inner:poll(ctx, self.inner_buf)
  if not cap then
    return nil
  end

  self.cap = cap
  out_capture(self.prep, self.f(unpack(self.inner_buf, 1, self.inner_buf.n)))
  out_copy(out, self.prep)
  return self
end

function Wrap:commit(ctx)
  if self.done then return end
  self.done = true

  local cap = assert(self.cap, 'wrap.commit: missing cap')
  cap:commit(ctx)

  local n = self.prep.n
  local a = self.prep

  self.cap = nil
  out_clear(self.inner_buf)

  return unpack(a, 1, n)
end

function Wrap:rollback(ctx, why)
  if self.done then return end
  self:_clear(ctx, why)
end

----------------------------------------------------------------------
-- guard(builder): evaluated once per synchronisation episode (perform)
----------------------------------------------------------------------

local Guard = {}
Guard.__index = Guard
mixin_base(Guard)

local function guard(builder)
  if type(builder) ~= 'function' then error('guard expects a function', 2) end
  return setmetatable({ builder = builder, inner = nil }, Guard)
end

function Guard:poll(ctx, out)
  if not self.inner then
    self.inner = self.builder()
  end
  return self.inner:poll(ctx, out)
end

function Guard:commit(ctx)
  return assert(self.inner, 'guard.commit: missing inner'):commit(ctx)
end

function Guard:rollback(ctx, why)
  if self.inner then
    self.inner:rollback(ctx, why)
    if (why or RB_ABORT) == RB_ABORT then
      self.inner = nil
    end
  end
end

----------------------------------------------------------------------
-- One-shot condition for nack (multi-waiter; uses Pulse for wakeups)
----------------------------------------------------------------------

local Cond = {}
Cond.__index = Cond

function Cond.new()
  return setmetatable({ fired = false, head = nil, tail = nil }, Cond)
end

local function cond_push(c, n)
  if n.inq then return end
  local t = c.tail
  n.prev, n.next, n.inq = t, nil, true
  if t then t.next = n else c.head = n end
  c.tail = n
end

local function cond_unlink(c, n)
  if not n or not n.inq then return end
  local p, nx = n.prev, n.next
  if p then p.next = nx else c.head = nx end
  if nx then nx.prev = p else c.tail = p end
  n.prev, n.next, n.inq = nil, nil, false
end

function Cond:signal()
  if self.fired then return end
  self.fired = true

  local n = self.head
  self.head, self.tail = nil, nil

  while n do
    local nx = n.next
    n.prev, n.next, n.inq = nil, nil, false
    local w = n.waker
    if w then w:signal() end
    n.waker = nil
    n = nx
  end
end

-- nack wait ticket: shareable across fibres by keying wait nodes by ctx.waker
local NackWait = {}
NackWait.__index = NackWait
mixin_base(NackWait)

function NackWait.new(cond)
  return setmetatable({
    cond  = cond,
    nodes = setmetatable({}, { __mode = 'k' }), -- key: Pulse (ctx.waker)
  }, NackWait)
end

function NackWait:poll(ctx, out)
  if self.cond.fired then
    out_clear(out)
    return self
  end

  local w = ctx.waker
  local node = self.nodes[w]
  if not node then
    node = { waker = w, prev = nil, next = nil, inq = false }
    self.nodes[w] = node
    cond_push(self.cond, node)
  else
    node.waker = w
  end

  return nil
end

function NackWait:commit(ctx)
  -- returns ready only when fired; commit is per-waiter and does not affect others
  local w = ctx.waker
  local node = self.nodes[w]
  if node then
    cond_unlink(self.cond, node)
    self.nodes[w] = nil
  end
  return true
end

function NackWait:rollback(ctx, _why)
  local w = ctx.waker
  local node = self.nodes[w]
  if node then
    cond_unlink(self.cond, node)
    self.nodes[w] = nil
  end
end

----------------------------------------------------------------------
-- with_nack(builder): builder receives a nack ticket that becomes ready on abort
----------------------------------------------------------------------

local WithNack = {}
WithNack.__index = WithNack
mixin_base(WithNack)

local function with_nack(builder)
  if type(builder) ~= 'function' then error('with_nack expects a function', 2) end
  return setmetatable({ builder = builder, inner = nil, cond = nil, nack = nil }, WithNack)
end

function WithNack:_ensure()
  if self.inner then return end
  local cond = Cond.new()
  local nack = NackWait.new(cond)
  self.cond = cond
  self.nack = nack
  self.inner = self.builder(nack)
end

function WithNack:poll(ctx, out)
  self:_ensure()
  return self.inner:poll(ctx, out)
end

function WithNack:commit(ctx)
  self:_ensure()
  return self.inner:commit(ctx)
end

function WithNack:rollback(ctx, why)
  self:_ensure()
  self.inner:rollback(ctx, why)

  if (why or RB_ABORT) == RB_ABORT and self.cond then
    self.cond:signal()
    -- end of episode; permit GC
    self.inner, self.cond, self.nack = nil, nil, nil
  end
end

----------------------------------------------------------------------
-- bracket(acquire, release, use) and finally(cleanup)
--
-- bracket is evaluated once per episode:
--   * acquire runs on first poll that reaches bracket
--   * release runs on commit (aborted=false) or abort rollback (aborted=true)
--   * invalidation rollback does NOT trigger release
----------------------------------------------------------------------

local Bracket = {}
Bracket.__index = Bracket
mixin_base(Bracket)

local function bracket(acquire, release, use)
  if type(acquire) ~= 'function' then error('bracket: acquire must be a function', 2) end
  if type(release) ~= 'function' then error('bracket: release must be a function', 2) end
  if type(use) ~= 'function' then error('bracket: use must be a function', 2) end
  return setmetatable({
    acquire = acquire,
    release = release,
    use     = use,

    res   = nil,
    inner = nil,
    cap   = nil,
    done  = false,
  }, Bracket)
end

function Bracket:_ensure()
  if self.res ~= nil then return end
  self.res   = self.acquire()
  self.inner = self.use(self.res)
end

function Bracket:poll(ctx, out)
  if self.done then return self end
  self:_ensure()

  -- validate cached cap once
  if self.cap then
    if self.cap:poll(ctx, nil) then
      -- bracket does not transform values; ask inner to populate out if requested
      if out then self.cap:poll(ctx, out) end
      return self
    end
    self.cap:rollback(ctx, RB_INVALID)
    self.cap = nil
  end

  local cap = self.inner:poll(ctx, out)
  if not cap then return nil end
  self.cap = cap
  return self
end

function Bracket:commit(ctx)
  if self.done then return end
  self.done = true

  local cap = assert(self.cap, 'bracket.commit: missing cap')
  local res = self.res

  self.cap = nil

  local ok, r = pcall(function() return pack(cap:commit(ctx)) end)
  local ok2, relerr = pcall(self.release, res, false)

  self.res, self.inner = nil, nil

  if not ok then error(r, 0) end
  if not ok2 then error(relerr, 0) end

  return unpack(r, 1, r.n)
end

function Bracket:rollback(ctx, why)
  if self.done then return end
  why = why or RB_ABORT

  if self.cap then
    self.cap:rollback(ctx, why)
    self.cap = nil
  elseif self.inner then
    self.inner:rollback(ctx, why)
  end

  if why == RB_ABORT and self.res ~= nil then
    pcall(self.release, self.res, true)
    self.res, self.inner = nil, nil
  end
end

function OpBase:finally(cleanup)
  if type(cleanup) ~= 'function' then error('finally expects a function', 2) end
  return bracket(
    function() return nil end,
    function(_, aborted) cleanup(aborted) end,
    function() return self end
  )
end

function OpBase:on_abort(f)
  if type(f) ~= 'function' then error('on_abort expects a function', 2) end
  return self:finally(function(aborted)
    if aborted then f() end
  end)
end

----------------------------------------------------------------------
-- Primitives
----------------------------------------------------------------------

local function always(...)
  local payload = pack(...)
  return new_primitive(
    function (self, _ctx, out)
      out_copy(out, self.payload)
      return self
    end,
    function (self, _ctx)
      self.done = true
      return unpack(self.payload, 1, self.payload.n)
    end,
    function (_self, _ctx, _why) end,
    { done = false, payload = payload }
  )
end

local function never()
  return new_primitive(
    function (self, ctx, _out)
      self.waker = ctx.waker
      return nil
    end,
    function (_self, _ctx)
      error('never: commit should be unreachable', 0)
    end,
    function (self, _ctx, _why)
      self.waker = nil
    end,
    { waker = nil }
  )
end

----------------------------------------------------------------------
-- choice(...)
--
-- Revised behaviour:
--   * Still returns the first ready arm (round-robin bias),
--     but continues to poll the remaining arms with out=nil.
--   * This ensures "once per perform" builders (guard/with_nack/bracket)
--     are evaluated for every arm that participates in the choice probe,
--     even if a winner is found early.
----------------------------------------------------------------------

local Choice = {}
Choice.__index = Choice
mixin_base(Choice)

local function choice(...)
  local ops = { ... }
  if #ops == 0 then error('choice expects at least one op', 2) end
  if #ops == 1 then return ops[1] end

  return setmetatable({
    ops = ops,
    n   = #ops,
    rr  = 1,

    done     = false,
    winner_i = nil,
    cap      = nil,

    sel = { winner = nil },
  }, Choice)
end

local function choice_reset(self)
  self.sel.winner = nil
  self.cap = nil
  self.winner_i = nil
end

function Choice:poll(ctx, out)
  if self.done then return self end

  local prev_sel = ctx.select_top
  ctx.select_top = self.sel

  -- 1) Validate cached winner cap once
  if self.cap then
    local ok = out and self.cap:poll(ctx, out) or self.cap:poll(ctx, nil)
    if ok then
      ctx.select_top = prev_sel
      return self
    end
    self.cap:rollback(ctx, RB_INVALID)
    choice_reset(self)
  end

  -- 2) Probe all arms once (round-robin order); pick first ready as winner
  local n = self.n
  local start = self.rr
  self.rr = (self.rr % n) + 1

  local winner_i, winner_cap = nil, nil

  for k = 0, n - 1 do
    local i = ((start + k - 1) % n) + 1
    local want_out = (winner_i == nil) and out or nil
    local cap = self.ops[i]:poll(ctx, want_out)

    if cap and not winner_i then
      winner_i, winner_cap = i, cap
      -- continue polling remaining arms with out=nil
    end
  end

  if winner_i then
    self.winner_i = winner_i
    self.cap      = winner_cap
    ctx.select_top = prev_sel
    return self
  end

  ctx.select_top = prev_sel
  return nil
end

function Choice:commit(ctx)
  if self.done then return end
  self.done = true

  local wi  = assert(self.winner_i, 'choice.commit: no winner')
  local cap = assert(self.cap, 'choice.commit: missing cap')

  for i = 1, self.n do
    if i ~= wi then
      self.ops[i]:rollback(ctx, RB_ABORT)
    end
  end

  choice_reset(self)
  return cap:commit(ctx)
end

function Choice:rollback(ctx, why)
  if self.done then return end
  why = why or RB_ABORT

  if self.cap then
    self.cap:rollback(ctx, why)
  end
  choice_reset(self)

  for i = 1, self.n do
    self.ops[i]:rollback(ctx, why)
  end
end

----------------------------------------------------------------------
-- all(...)
----------------------------------------------------------------------

local All = {}
All.__index = All
mixin_base(All)

local function all(...)
  local ops = { ... }
  if #ops == 0 then error('all expects at least one op', 2) end
  if #ops == 1 then return ops[1] end

  local prep = { n = #ops }
  for i = 1, #ops do
    prep[i] = { n = 0 }
  end

  return setmetatable({
    ops = ops,
    n   = #ops,

    done = false,
    caps = nil,

    prep = prep,
  }, All)
end

local function all_clear(self)
  self.caps = nil
  for i = 1, self.n do
    out_clear(self.prep[i])
  end
end

function All:poll(ctx, out)
  if self.done then return self end

  -- 1) Validate cached caps once
  if self.caps then
    for i = 1, self.n do
      if not self.caps[i]:poll(ctx, nil) then
        for j = 1, self.n do
          self.caps[j]:rollback(ctx, RB_INVALID)
        end
        all_clear(self)
        break
      end
    end

    if self.caps then
      if out then
        out.n = self.n
        for i = 1, self.n do out[i] = self.prep[i] end
      end
      return self
    end
  end

  -- 2) Acquire once
  local caps = {}
  for i = 1, self.n do
    local cap = self.ops[i]:poll(ctx, self.prep[i])
    if not cap then
      for j = 1, i - 1 do
        caps[j]:rollback(ctx, RB_INVALID)
        out_clear(self.prep[j])
      end
      return nil
    end
    caps[i] = cap
  end

  self.caps = caps
  if out then
    out.n = self.n
    for i = 1, self.n do out[i] = self.prep[i] end
  end
  return self
end

function All:commit(ctx)
  if self.done then return end
  self.done = true

  for i = 1, self.n do
    self.caps[i]:commit(ctx)
  end
  self.caps = nil

  return unpack(self.prep, 1, self.n)
end

function All:rollback(ctx, why)
  if self.done then return end
  why = why or RB_ABORT

  if self.caps then
    for i = 1, self.n do
      self.caps[i]:rollback(ctx, why)
    end
  end
  all_clear(self)

  for i = 1, self.n do
    self.ops[i]:rollback(ctx, why)
  end
end

----------------------------------------------------------------------
-- and_then(lhs, k)
----------------------------------------------------------------------

AndThen = {}
AndThen.__index = AndThen
mixin_base(AndThen)

function AndThen.new(lhs, k)
  return setmetatable({
    lhs = lhs,
    k   = k,

    done = false,

    cap1 = nil,
    v1   = { n = 0 },

    rhs  = nil,
    cap2 = nil,
    v2   = { n = 0 },
  }, AndThen)
end

function AndThen:_clear_rhs(ctx, why)
  why = why or RB_ABORT
  if self.cap2 then
    self.cap2:rollback(ctx, why)
    self.cap2 = nil
  elseif self.rhs then
    self.rhs:rollback(ctx, why)
  end
  self.rhs = nil
  out_clear(self.v2)
end

function AndThen:_restart(ctx, why)
  why = why or RB_ABORT
  self:_clear_rhs(ctx, why)
  if self.cap1 then
    self.cap1:rollback(ctx, why)
    self.cap1 = nil
  else
    self.lhs:rollback(ctx, why)
  end
  out_clear(self.v1)
end

function AndThen:poll(ctx, out)
  if self.done then return self end

  -- 1) Validate cached cap2 once
  if self.cap2 then
    if self.cap2:poll(ctx, nil) then
      out_copy(out, self.v2)
      return self
    end
    self:_clear_rhs(ctx, RB_INVALID)
  end

  -- 2) Ensure cap1 is valid / acquired
  if self.cap1 then
    if not self.cap1:poll(ctx, nil) then
      self:_restart(ctx, RB_INVALID)
    end
  end

  if not self.cap1 then
    local cap1 = self.lhs:poll(ctx, self.v1)
    if not cap1 then return nil end
    self.cap1 = cap1
    self.rhs  = self.k(unpack(self.v1, 1, self.v1.n))
  end

  -- 3) Acquire cap2 once
  local cap2 = self.rhs:poll(ctx, self.v2)
  if not cap2 then
    return nil
  end

  self.cap2 = cap2
  out_copy(out, self.v2)
  return self
end

function AndThen:commit(ctx)
  if self.done then return end
  self.done = true

  local cap1 = assert(self.cap1, 'and_then.commit: missing cap1')
  local cap2 = assert(self.cap2, 'and_then.commit: missing cap2')

  cap1:commit(ctx)

  self.cap1 = nil
  self.rhs  = nil
  self.cap2 = nil
  out_clear(self.v1)
  out_clear(self.v2)

  return cap2:commit(ctx)
end

function AndThen:rollback(ctx, why)
  if self.done then return end
  self:_restart(ctx, why)
end

----------------------------------------------------------------------
-- Unbuffered channel as transactional tickets (targeted waking)
----------------------------------------------------------------------

local Channel = {}
Channel.__index = Channel

function Channel.new()
  if not runtime.sched then error('runtime not initialised (call init(sched))', 2) end
  return setmetatable({
    put_h = nil,
    put_t = nil,
    get_h = nil,
    get_t = nil,
  }, Channel)
end

local function unlink_put(ch, n)
  if not n.inq then return end
  local prev, next = n.prev, n.next
  if prev then prev.next = next else ch.put_h = next end
  if next then next.prev = prev else ch.put_t = prev end
  n.prev, n.next, n.inq = nil, nil, false
end

local function unlink_get(ch, n)
  if not n.inq then return end
  local prev, next = n.prev, n.next
  if prev then prev.next = next else ch.get_h = next end
  if next then next.prev = prev else ch.get_t = prev end
  n.prev, n.next, n.inq = nil, nil, false
end

local function push_put(ch, n)
  if n.inq then return end
  local tail = ch.put_t
  n.prev, n.next, n.inq = tail, nil, true
  if tail then tail.next = n else ch.put_h = n end
  ch.put_t = n
end

local function push_get(ch, n)
  if n.inq then return end
  local tail = ch.get_t
  n.prev, n.next, n.inq = tail, nil, true
  if tail then tail.next = n else ch.get_h = n end
  ch.get_t = n
end

local function wake(node)
  local w = node and node.waker
  if w then w:signal() end
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

local function detach_uncommitted(_, a, b)
  if a.peer == b then a.peer = nil end
  if b.peer == a then b.peer = nil end
  wake(a)
  wake(b)
end

local function commit_pair(ch, putop, getop)
  if putop.done or getop.done then return end

  putop.done = true
  getop.done = true
  getop.result = putop.val

  unlink_put(ch, putop)
  unlink_get(ch, getop)

  putop.peer = nil
  getop.peer = nil
  getop.sel  = nil

  local pw, gw = putop.waker, getop.waker
  putop.waker, getop.waker = nil, nil

  if pw then pw:signal() end
  if gw then gw:signal() end
end

-- Put ticket
local Put = {}
Put.__index = Put
mixin_base(Put)

function Channel:put_op(val)
  return setmetatable({
    ch  = self,
    val = val,

    waker = nil,
    peer  = nil,
    done  = false,

    prev = nil,
    next = nil,
    inq = false,
  }, Put)
end

function Put:poll(ctx, out)
  local ch = self.ch
  if self.done then
    out_clear(out)
    return self
  end

  if self.waker and self.waker ~= ctx.waker then
    error('put ticket used from a different fibre', 0)
  end
  self.waker = ctx.waker

  local g = self.peer
  if g then
    local sel = g.sel
    if sel and sel.winner == nil then
      return nil
    end
    if sel and sel.winner ~= g then
      detach_uncommitted(ch, self, g)
      return nil
    end
    out_clear(out)
    return self
  end

  local r = find_eligible_get(ch.get_h)
  if r then
    self.peer = r
    r.peer = self
    wake(r)

    local sel = r.sel
    if sel and sel.winner == nil then
      return nil
    end

    out_clear(out)
    return self
  end

  push_put(ch, self)
  return nil
end

function Put:commit(_)
  if self.done then return end
  local g = self.peer
  if g then
    commit_pair(self.ch, self, g)
  end
end

function Put:rollback(_ctx, _why)
  if self.done then return end
  local ch = self.ch
  local g = self.peer
  if g and (not g.done) then
    detach_uncommitted(ch, self, g)
  end
  self.peer  = nil
  self.waker = nil
  unlink_put(ch, self)
end

-- Get ticket
local Get = {}
Get.__index = Get
mixin_base(Get)

function Channel:get_op()
  return setmetatable({
    ch = self,

    waker  = nil,
    peer   = nil,
    result = nil,
    done   = false,

    prepared = false,
    prep_val = nil,
    prep_peer = nil, -- strengthen prepared validation

    sel = nil,

    prev = nil,
    next = nil,
    inq = false,
  }, Get)
end

local function get_loses_selection(self)
  local ch = self.ch
  local p = self.peer
  if p and (not p.done) then
    detach_uncommitted(ch, p, self)
  end
  self.peer      = nil
  self.prepared  = false
  self.prep_val  = nil
  self.prep_peer = nil
  unlink_get(ch, self)
end

function Get:poll(ctx, out)
  local ch = self.ch
  if self.done then
    out_set1(out, self.result)
    return self
  end

  if self.waker and self.waker ~= ctx.waker then
    error('get ticket used from a different fibre', 0)
  end
  self.waker = ctx.waker
  self.sel   = ctx.select_top

  local sel = self.sel
  if sel and sel.winner and sel.winner ~= self then
    get_loses_selection(self)
    return nil
  end

  if self.prepared then
    local p = self.peer
    if not p or p.done or p ~= self.prep_peer or p.val ~= self.prep_val then
      return nil
    end

    if sel and sel.winner == nil then
      sel.winner = self
      wake(p)
    end
    if sel and sel.winner ~= self then
      return nil
    end

    out_set1(out, self.prep_val)
    return self
  end

  local p = self.peer
  if p then
    if sel and sel.winner == nil then
      sel.winner = self
      wake(p)
    end
    if sel and sel.winner ~= self then
      return nil
    end

    if out then
      self.prepared  = true
      self.prep_val  = p.val
      self.prep_peer = p
      out_set1(out, self.prep_val)
    end
    return self
  end

  local s = find_unmatched_put(ch.put_h)
  if s then
    if sel and sel.winner == nil then
      sel.winner = self
    end
    if sel and sel.winner ~= self then
      return nil
    end

    self.peer = s
    s.peer = self
    wake(s)

    if out then
      self.prepared  = true
      self.prep_val  = s.val
      self.prep_peer = s
      out_set1(out, self.prep_val)
    end
    return self
  end

  push_get(ch, self)
  return nil
end

function Get:commit(_)
  if self.done then return self.result end
  local p = self.peer
  if p then
    commit_pair(self.ch, p, self)
  end
  self.prepared  = false
  self.prep_val  = nil
  self.prep_peer = nil
  return self.result
end

function Get:rollback(_ctx, _why)
  if self.done then return end
  local ch = self.ch
  local p = self.peer
  if p and (not p.done) then
    detach_uncommitted(ch, p, self)
  end
  self.peer      = nil
  self.sel       = nil
  self.waker     = nil
  self.prepared  = false
  self.prep_val  = nil
  self.prep_peer = nil
  unlink_get(ch, self)
end

function Channel:put(v) return perform(self:put_op(v)) end
function Channel:get() return perform(self:get_op()) end

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
  init(Scheduler.new())

  local ch  = Channel.new()
  local sum = 0

  spawn(function ()
    for i = 1, N do
      ch:put(i)
    end
  end, 'bench_put')

  spawn(function ()
    for _ = 1, N do
      sum = sum + (ch:get() or 0)
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
  init(Scheduler.new())

  local a   = Channel.new()
  local b   = Channel.new()
  local sum = 0

  -- Single sender alternates puts between channels.
  spawn(function ()
    for i = 1, N do
      if (i % 2) == 1 then
        a:put(i)
      else
        b:put(i)
      end
    end
  end, 'bench_sender')

  -- Single receiver uses choice(get(a), get(b)).
  spawn(function ()
    for _ = 1, N do
      local v = perform(choice(a:get_op(), b:get_op()))
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

----------------------------------------------------------------------
-- Run benchmarks
----------------------------------------------------------------------

local N = tonumber(arg and arg[1]) or 200000

io.write(('\n[bench] starting (N=%d)\n'):format(N))
bench_channel_rendezvous(N)
bench_choice_alternating(N)

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

return {
  -- runtime
  Scheduler = Scheduler,
  init      = init,
  spawn     = spawn,
  main      = main,
  perform   = perform,
  runtime   = runtime,

  -- primitives & combinators
  new_primitive = new_primitive,
  always        = always,
  never         = never,

  choice   = choice,
  all      = all,
  guard    = guard,
  with_nack = with_nack,
  bracket  = bracket,

  -- channel
  Channel  = Channel,
}

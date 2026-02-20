-- fibers/op.lua
--=============================================================================
-- Op API (internal):
--   poll(ctx, out) -> boolean ready
--   commit(ctx)    -> ...results...
--   rollback(ctx, why)
--=============================================================================

local runtime = require 'fibers.runtime'
local List    = require 'fibers.utils.intrusive_list'

local unpack = rawget(table, 'unpack') or _G.unpack
local function pack(...) return { n = select('#', ...), ... } end

---@class OutBuf
---@field n integer
---@field [integer] any

---@class OpCtx
---@field waker any
---@field in_perform boolean
---@field select_top any|nil

---@class Op
---@field poll fun(self: Op, ctx: OpCtx, out: OutBuf|nil): boolean
---@field commit fun(self: Op, ctx: OpCtx): ...
---@field rollback fun(self: Op, ctx: OpCtx, why: string|nil): nil

local RB_ABORT   = 'rb_abort'
local RB_INVALID = 'rb_invalid'

local function rollback_ops(ctx, ops, why, skip_i)
  for i = 1, #ops do
    if i ~= skip_i then ops[i]:rollback(ctx, why) end
  end
end

-- --------------------------------------------------------------------------
-- Prepared out-buffers (reusable tables)
-- --------------------------------------------------------------------------

local function out_clear(out)
  if not out then return end
  local old = out.n or 0
  out.n = 0
  for i = 1, old do out[i] = nil end
end

local function out_copy(dst, src)
  if not dst or dst == src then return end
  local old = dst.n or 0
  local n   = src.n or 0
  dst.n     = n
  for i = 1, n do dst[i] = src[i] end
  for i = n + 1, old do dst[i] = nil end
end

local function out_capture(out, ...)
  if not out then return end
  local old = out.n or 0
  local n   = select('#', ...)
  out.n     = n
  for i = 1, n do out[i] = select(i, ...) end
  for i = n + 1, old do out[i] = nil end
end

-- --------------------------------------------------------------------------
-- perform(op)
-- --------------------------------------------------------------------------

local function finish_perform(ctx, ...)
  ctx.in_perform = false
  return ...
end

---Perform an Op, yielding cooperatively until it becomes ready.
---Must be called from inside a fibre.
---@param op Op
---@return ... any
local function perform(op)
  local ctx = runtime.ctx() ---@type OpCtx
  if ctx.in_perform then error('perform is not re-entrant', 0) end
  ctx.in_perform = true

  local w = ctx.waker
  while true do
    if op:poll(ctx, nil) then
      return finish_perform(ctx, op:commit(ctx))
    end
    ctx.in_perform = false
    coroutine.yield(w)
    ctx.in_perform = true
  end
end

-- --------------------------------------------------------------------------
-- Op base (inherited via metatable)
-- --------------------------------------------------------------------------

local Wrap, AndThen, bracket

---@type Op
local Op = {}
Op.__index = Op

---Pure value transformation (no cleanup).
---@param f fun(...: any): ...
---@return Op
function Op:wrap(f)
  if type(f) ~= 'function' then error('wrap expects a function', 2) end
  return Wrap.new(self, f)
end

---Transactional bind: prepares lhs, derives rhs via k(...), and commits lhs only when rhs is also ready to commit.
---@param k fun(...: any): Op
---@return Op
function Op:and_then(k)
  if type(k) ~= 'function' then error('and_then expects a function', 2) end
  return AndThen.new(self, k)
end

---Attach cleanup called on commit and abort.
---@param cleanup fun(aborted: boolean)
---@return Op
function Op:finally(cleanup)
  if type(cleanup) ~= 'function' then error('finally expects a function', 2) end
  return bracket(
    function () return nil end,
    function (_, aborted) cleanup(aborted) end,
    function () return self end
  )
end

---Run f() if this op is aborted (loses in a choice).
---@param f fun()
---@return Op
function Op:on_abort(f)
  if type(f) ~= 'function' then error('on_abort expects a function', 2) end
  return self:finally(function (aborted) if aborted then f() end end)
end

local function inherit(proto)
  proto.__index = proto
  return setmetatable(proto, Op)
end

-- --------------------------------------------------------------------------
-- Primitive constructor (no per-instance closures required)
-- --------------------------------------------------------------------------

local function noop() end
local PrimMT = { __index = Op }

---Create a primitive Op from shared poll/commit/rollback functions and a state table.
---@param poll_fn fun(self: any, ctx: OpCtx, out: OutBuf|nil): boolean
---@param commit_fn fun(self: any, ctx: OpCtx): ...
---@param rollback_fn? fun(self: any, ctx: OpCtx, why: string|nil): nil
---@param state? table
---@return Op
local function new_primitive(poll_fn, commit_fn, rollback_fn, state)
  if type(poll_fn) ~= 'function' then error('new_primitive: poll_fn must be a function', 2) end
  if type(commit_fn) ~= 'function' then error('new_primitive: commit_fn must be a function', 2) end
  rollback_fn = rollback_fn or noop
  if type(rollback_fn) ~= 'function' then error('new_primitive: rollback_fn must be a function or nil', 2) end

  local obj = state or {}
  obj.poll     = poll_fn
  obj.commit   = commit_fn
  obj.rollback = rollback_fn
  return setmetatable(obj, PrimMT)
end

-- --------------------------------------------------------------------------
-- Cached-wrapper helpers (inner/ready/prep pattern)
-- --------------------------------------------------------------------------

local function cached_poll(self, ctx, out)
  if self.ready then
    if not self.inner:poll(ctx, nil) then
      self.inner:rollback(ctx, RB_INVALID)
      self.ready = false
      out_clear(self.prep)
    else
      out_copy(out, self.prep)
      return true
    end
  end

  if not self.inner:poll(ctx, self.prep) then
    return false
  end

  self.ready = true
  out_copy(out, self.prep)
  return true
end

local function cached_commit(self, ctx, label)
  if self.done then return end
  self.done = true
  assert(self.ready, label .. '.commit: not ready')

  self.ready = false
  out_clear(self.prep)
  return self.inner:commit(ctx)
end

local function cached_rollback(self, ctx, why)
  if self.done then return false end
  why = why or RB_ABORT
  local inner = self.inner
  if not inner then return false end

  inner:rollback(ctx, why)
  self.ready = false
  out_clear(self.prep)
  return true
end

-- --------------------------------------------------------------------------
-- Wrap op (internal)
-- --------------------------------------------------------------------------

Wrap = inherit({})

function Wrap.new(inner, f)
  return setmetatable({
    inner = inner,
    f     = f,
    ready = false,
    done  = false,
    inner_buf = { n = 0 },
    prep      = { n = 0 },
  }, Wrap)
end

function Wrap:_clear(ctx, why)
  self.inner:rollback(ctx, why or RB_ABORT)
  self.ready = false
  out_clear(self.inner_buf)
  out_clear(self.prep)
end

function Wrap:poll(ctx, out)
  if self.done then return true end

  if self.ready then
    if not self.inner:poll(ctx, nil) then
      self:_clear(ctx, RB_INVALID)
    else
      out_copy(out, self.prep)
      return true
    end
  end

  if not self.inner:poll(ctx, self.inner_buf) then
    return false
  end

  self.ready = true
  out_capture(self.prep, self.f(unpack(self.inner_buf, 1, self.inner_buf.n)))
  out_copy(out, self.prep)
  return true
end

function Wrap:commit(ctx)
  if self.done then return end
  self.done = true
  assert(self.ready, 'wrap.commit: not ready')

  self.inner:commit(ctx)

  local a, n = self.prep, self.prep.n
  self.ready = false
  out_clear(self.inner_buf)
  return unpack(a, 1, n)
end

function Wrap:rollback(ctx, why)
  if self.done then return end
  self:_clear(ctx, why)
end

-- --------------------------------------------------------------------------
-- guard(builder) (public constructor; internal type)
-- --------------------------------------------------------------------------

local Guard = inherit({})

---Build an op lazily, once per synchronisation attempt.
---@param builder fun(): Op
---@return Op
local function guard(builder)
  if type(builder) ~= 'function' then error('guard expects a function', 2) end
  return setmetatable({
    builder = builder,
    inner   = nil,
    ready   = false,
    done    = false,
    prep    = { n = 0 },
  }, Guard)
end

function Guard:_ensure()
  if not self.inner then self.inner = self.builder() end
end

function Guard:poll(ctx, out)
  if self.done then return true end
  self:_ensure()
  return cached_poll(self, ctx, out)
end

function Guard:commit(ctx)
  self:_ensure()
  return cached_commit(self, ctx, 'guard')
end

function Guard:rollback(ctx, why)
  if cached_rollback(self, ctx, why) and (why or RB_ABORT) == RB_ABORT then
    self.inner = nil
  end
end

-- --------------------------------------------------------------------------
-- with_nack(builder) (public constructor; internal types)
-- --------------------------------------------------------------------------

local Cond = {}
Cond.__index = Cond

function Cond.new()
  return setmetatable({ fired = false, list = List.new() }, Cond)
end

function Cond:signal()
  if self.fired then return end
  self.fired = true
  local l = self.list
  while true do
    local n = l:pop_head_node()
    if not n then break end
    local w = n.waker
    n.waker = nil
    if w then w:signal() end
  end
end

local NackWait = inherit({})

function NackWait.new(cond)
  return setmetatable({
    cond  = cond,
    nodes = setmetatable({}, { __mode = 'k' }),
    done  = false,
  }, NackWait)
end

function NackWait:poll(ctx, out)
  if self.done or self.cond.fired then
    out_clear(out)
    return true
  end
  local w = ctx.waker
  local node = self.nodes[w]
  if not node then
    node = { waker = w, prev = nil, next = nil, inq = false }
    self.nodes[w] = node
    self.cond.list:push(node)
  else
    node.waker = w
  end
  return false
end

function NackWait:_unlink(ctx)
  local w = ctx.waker
  local node = self.nodes[w]
  if node then
    self.cond.list:unlink(node)
    self.nodes[w] = nil
  end
end

function NackWait:commit(ctx)
  self.done = true
  self:_unlink(ctx)
  return true
end

function NackWait:rollback(ctx, _)
  self:_unlink(ctx)
end

local WithNack = inherit({})

---CML-style nack support; builder is passed nack(): Op which becomes ready if this arm is aborted.
---@param builder fun(nack: fun(): Op): Op
---@return Op
local function with_nack(builder)
  if type(builder) ~= 'function' then error('with_nack expects a function', 2) end
  return setmetatable({
    builder = builder,
    inner   = nil,
    cond    = nil,
    ready   = false,
    done    = false,
    prep    = { n = 0 },
  }, WithNack)
end

function WithNack:_ensure()
  if self.inner then return end
  local cond = Cond.new()
  local function nack() return NackWait.new(cond) end
  self.cond = cond
  self.inner = self.builder(nack)
end

function WithNack:poll(ctx, out)
  if self.done then return true end
  self:_ensure()
  return cached_poll(self, ctx, out)
end

function WithNack:commit(ctx)
  self:_ensure()
  return cached_commit(self, ctx, 'with_nack')
end

function WithNack:rollback(ctx, why)
  if not cached_rollback(self, ctx, why) then return end
  if (why or RB_ABORT) == RB_ABORT and self.cond then
    self.cond:signal()
    self.inner, self.cond = nil, nil
  end
end

-- --------------------------------------------------------------------------
-- bracket(acquire, release, use) (public constructor; internal type)
-- --------------------------------------------------------------------------

local Bracket = inherit({})

---Resource-safe wrapper: acquire(), then use(res), then release(res, aborted) on commit/abort.
---@param acquire fun(): any
---@param release fun(res: any, aborted: boolean)
---@param use fun(res: any): Op
---@return Op
function bracket(acquire, release, use)
  if type(acquire) ~= 'function' then error('bracket: acquire must be a function', 2) end
  if type(release) ~= 'function' then error('bracket: release must be a function', 2) end
  if type(use) ~= 'function' then error('bracket: use must be a function', 2) end

  return setmetatable({
    acquire = acquire,
    release = release,
    use     = use,
    res      = nil,
    inner    = nil,
    acquired = false,
    ready = false,
    done  = false,
  }, Bracket)
end

function Bracket:_ensure()
  if self.acquired then return end
  self.res      = self.acquire()
  self.inner    = self.use(self.res)
  self.acquired = true
end

function Bracket:_release(aborted)
  if not self.acquired then return end
  local res = self.res
  self.res, self.inner, self.acquired = nil, nil, false
  pcall(self.release, res, aborted)
end

function Bracket:poll(ctx, out)
  if self.done then return true end
  self:_ensure()

  if self.ready then
    if not self.inner:poll(ctx, nil) then
      self.inner:rollback(ctx, RB_INVALID)
      self.ready = false
    else
      return true
    end
  end

  if not self.inner:poll(ctx, out) then return false end
  self.ready = true
  return true
end

function Bracket:commit(ctx)
  if self.done then return end
  self.done = true

  self:_ensure()
  assert(self.ready, 'bracket.commit: not ready')
  self.ready = false

  local ok, r = pcall(function () return pack(self.inner:commit(ctx)) end)
  local ok2, relerr = pcall(function () self:_release(false) end)
  if not ok  then error(r, 0) end
  if not ok2 then error(relerr, 0) end
  return unpack(r, 1, r.n)
end

function Bracket:rollback(ctx, why)
  if self.done then return end
  why = why or RB_ABORT
  if self.inner then self.inner:rollback(ctx, why) end
  self.ready = false
  if why == RB_ABORT then self:_release(true) end
end

-- --------------------------------------------------------------------------
-- Primitives: always / never
-- --------------------------------------------------------------------------

local function always_poll(self, _, out) out_copy(out, self.payload); return true end
local function always_commit(self, _) self.done = true; return unpack(self.payload, 1, self.payload.n) end

---@param ... any
---@return Op
local function always(...)
  return new_primitive(always_poll, always_commit, nil, {
    done    = false,
    payload = pack(...),
  })
end

local function never_poll(self, ctx, _) self.waker = ctx.waker; return false end
local function never_commit() error('never: commit should be unreachable', 0) end
local function never_rollback(self) self.waker = nil end

---@return Op
local function never()
  return new_primitive(never_poll, never_commit, never_rollback, { waker = nil })
end

-- --------------------------------------------------------------------------
-- choice(...)
-- --------------------------------------------------------------------------

local Choice = inherit({})

---Race a set of ops; becomes ready when any arm is ready and aborts the losers on commit.
---@param ... Op
---@return Op
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
    prep = { n = 0 },
    sel  = { winner = nil },
  }, Choice)
end

local function choice_reset(self)
  self.sel.winner = nil
  self.winner_i = nil
  out_clear(self.prep)
end

function Choice:poll(ctx, out)
  if self.done then return true end

  local prev_sel = ctx.select_top
  ctx.select_top = self.sel

  if self.winner_i then
    local wi = self.winner_i
    if self.ops[wi]:poll(ctx, nil) then
      out_copy(out, self.prep)
      ctx.select_top = prev_sel
      return true
    end
    self.ops[wi]:rollback(ctx, RB_INVALID)
    choice_reset(self)
  end

  local ops, n = self.ops, self.n
  local i = self.rr
  self.rr = (i % n) + 1

  local winner_i
  for _ = 1, n do
    local want_out = (winner_i == nil) and self.prep or nil
    if ops[i]:poll(ctx, want_out) and not winner_i then winner_i = i end
    i = (i % n) + 1
  end

  ctx.select_top = prev_sel

  if winner_i then
    self.winner_i = winner_i
    out_copy(out, self.prep)
    return true
  end
  return false
end

function Choice:commit(ctx)
  if self.done then return end
  self.done = true

  local wi = assert(self.winner_i, 'choice.commit: no winner')
  local win = self.ops[wi]

  rollback_ops(ctx, self.ops, RB_ABORT, wi)
  choice_reset(self)
  return win:commit(ctx)
end

function Choice:rollback(ctx, why)
  if self.done then return end
  choice_reset(self)
  rollback_ops(ctx, self.ops, why or RB_ABORT)
end

-- --------------------------------------------------------------------------
-- all(...)
-- --------------------------------------------------------------------------

local All = inherit({})

---Join a set of ops; becomes ready only when all arms are ready and commits them all,
---returning a packed buffer of values per each op.
---@param ... Op
---@return Op
local function all(...)
  local ops = { ... }
  if #ops == 0 then error('all expects at least one op', 2) end
  if #ops == 1 then return ops[1] end

  local prep = { n = #ops }
  for i = 1, #ops do prep[i] = { n = 0 } end

  return setmetatable({
    ops = ops,
    n   = #ops,
    done  = false,
    ready = false,
    prep  = prep,
  }, All)
end

local function all_clear(self)
  self.ready = false
  for i = 1, self.n do out_clear(self.prep[i]) end
end

function All:poll(ctx, out)
  if self.done then return true end
  local ops, n = self.ops, self.n

  if self.ready then
    for i = 1, n do
      if not ops[i]:poll(ctx, nil) then
        for j = 1, n do ops[j]:rollback(ctx, RB_INVALID) end
        all_clear(self)
        break
      end
    end
    if self.ready then
      if out then out.n = n; for i = 1, n do out[i] = self.prep[i] end end
      return true
    end
  end

  for i = 1, n do
    if not ops[i]:poll(ctx, self.prep[i]) then
      for j = 1, i - 1 do ops[j]:rollback(ctx, RB_INVALID); out_clear(self.prep[j]) end
      return false
    end
  end

  self.ready = true
  if out then out.n = n; for i = 1, n do out[i] = self.prep[i] end end
  return true
end

function All:commit(ctx)
  if self.done then return end
  self.done = true
  for i = 1, self.n do self.ops[i]:commit(ctx) end
  self.ready = false
  return unpack(self.prep, 1, self.n)
end

function All:rollback(ctx, why)
  if self.done then return end
  all_clear(self)
  rollback_ops(ctx, self.ops, why or RB_ABORT)
end

-- --------------------------------------------------------------------------
-- and_then(lhs, k)
-- --------------------------------------------------------------------------

AndThen = inherit({})

function AndThen.new(lhs, k)
  return setmetatable({
    lhs = lhs,
    k   = k,
    done   = false,
    ready1 = false,
    v1     = { n = 0 },
    rhs    = nil,
    ready2 = false,
    v2     = { n = 0 },
  }, AndThen)
end

function AndThen:_clear_rhs(ctx, why)
  if self.rhs then self.rhs:rollback(ctx, why or RB_ABORT) end
  self.rhs, self.ready2 = nil, false
  out_clear(self.v2)
end

function AndThen:_restart(ctx, why)
  self:_clear_rhs(ctx, why)
  self.lhs:rollback(ctx, why or RB_ABORT)
  self.ready1 = false
  out_clear(self.v1)
end

function AndThen:poll(ctx, out)
  if self.done then return true end

  if self.ready2 then
    if self.rhs:poll(ctx, nil) then out_copy(out, self.v2); return true end
    self:_clear_rhs(ctx, RB_INVALID)
  end

  if self.ready1 and not self.lhs:poll(ctx, nil) then
    self:_restart(ctx, RB_INVALID)
  end

  if not self.ready1 then
    if not self.lhs:poll(ctx, self.v1) then return false end
    self.ready1 = true
    self.rhs    = self.k(unpack(self.v1, 1, self.v1.n))
  end

  if not self.rhs:poll(ctx, self.v2) then return false end
  self.ready2 = true
  out_copy(out, self.v2)
  return true
end

function AndThen:commit(ctx)
  if self.done then return end
  self.done = true

  assert(self.ready1, 'and_then.commit: lhs not ready')
  assert(self.ready2, 'and_then.commit: rhs not ready')
  local rhs = assert(self.rhs, 'and_then.commit: missing rhs')

  self.lhs:commit(ctx)

  self.ready1, self.ready2, self.rhs = false, false, nil
  out_clear(self.v1)
  out_clear(self.v2)

  return rhs:commit(ctx)
end

function AndThen:rollback(ctx, why)
  if self.done then return end
  self:_restart(ctx, why)
end

-- --------------------------------------------------------------------------
-- Public API
-- --------------------------------------------------------------------------

return {
  Op = Op,
  perform = perform,
  new_primitive = new_primitive,
  always = always,
  never = never,
  choice = choice,
  all = all,
  guard = guard,
  with_nack = with_nack,
  bracket = bracket,
  RB_ABORT = RB_ABORT,
  RB_INVALID = RB_INVALID,
}

-- fibers/scope.lua
-- Scope: select/wait; cancellation & timeout; branch defers.
-- Lua 5.1 / LuaJIT

local fiber  = require 'fibers.fiber'
local waitgroup = require 'fibers.waitgroup'

local unpack = rawget(table, "unpack") or _G.unpack         -- Lua 5.1 fallback
local pack   = rawget(table, "pack")   or function(...)      -- Lua 5.1 fallback
  return { n = select("#", ...), ... }
end

local Scope = {}
Scope.__index = Scope

local function monotime()
  return fiber.current_scheduler:monotime()
end

-- ==== helpers ================================================================

-- pcall, but return (ok:boolean, packed_results:table)
local function pcall_pack(f, ...)
  local t = { pcall(f, ...) }
  local ok = table.remove(t, 1)
  return ok, pack(unpack(t))
end

-- Call op:_try_call() with proper error handling and packing
local function try_pack(op)
  return pcall_pack(function() return op:_try_call() end)
end

-- Call op:_wrap_call(...) with proper error handling and packing
local function wrap_pack(op, values)
  return pcall_pack(function()
    return op:_wrap_call(unpack(values, 1, values.n))
  end)
end

local function order_indices(n, policy, rr)
  if n <= 1 then return {1} end
  local idx = {}
  if policy == "first-ready" then
    for i=1,n do idx[i]=i end
  elseif policy == "fair" then
    local start = (rr % n) + 1
    for i=1,n do idx[i] = ((start + i - 2) % n) + 1 end
  else -- "random"
    local start = math.random(n)
    for i = 1, n do idx[i] = ((start + i - 2) % n) + 1 end
  end
  return idx
end

local function run_hooks(list) -- LIFO, ignore errors
  for i = #list, 1, -1 do
    local fn = list[i]
    if fn then pcall(fn) end
  end
end

-- ==== per-select suspension ==================================================

local Susp = {}
Susp.__index = Susp
function Susp:waiting() return not self._st.done end
function Susp:complete(...)
  if self._st.done then return end
  self._st.done = true
  local values = pack(...)
  local st = self._st
  if not st._sched or not st._fib then
    st.pending = { idx = self._idx, values = values }
    return
  end
  st._sched:schedule({
    run = function()
      st._fib:resume(function(i, ...)
        st.idx     = i
        st.values  = pack(...)
      end, self._idx, unpack(values, 1, values.n))
    end
  })
end

local function make_susp(st, idx)
  return setmetatable({ _st = st, _idx = idx }, Susp)
end

local function block_select(sched, fib, st)
  st._sched, st._fib = sched, fib
  if st.done and st.pending then
    local p = st.pending; st.pending = nil
    sched:schedule({
      run = function()
        fib:resume(function(i, ...)
          st.idx    = i
          st.values = pack(...)
        end, p.idx, unpack(p.values, 1, p.values.n))
      end
    })
  end
end

-- ==== Scope ==================================================================

local function new(parent, opts)
  opts = opts or {}
  return setmetatable({
    parent    = parent,
    policy    = opts.select_policy or "random",
    timeout   = opts.timeout, -- seconds (monotonic)
    deadline  = opts.timeout and (monotime() + opts.timeout) or nil,
    canceled  = false,
    cause     = nil,
    _rr       = 0,     -- fairness cursor
    _active   = {},    -- current select state
    _in_phase = false, -- debug guard for install/hooks
    name      = opts.name,
    -- structured concurrency state
    _wg       = waitgroup.new(),
    _children = {}
  }, Scope)
end

function Scope:is_canceled() return self.canceled end
function Scope:cause() return self.cause end

function Scope:deadline_at() return self.deadline end

function Scope:cancel(cause)
  if self.canceled then return end
  self.canceled, self.cause = true, (cause or "canceled")
  for st, _ in pairs(self._active) do
    if not st.done then
      st.done, st.scause = true, self.cause
      local sched, fib = st._sched, st._fib
      if sched and fib then
        sched:schedule({ run = function() fib:resume(function(i) st.idx = i end, 0) end })
      else
        st.pending = { idx = 0, values = pack() }
      end
    end
  end
end

-- returns: ok:boolean, idx_or_cause, ...values
function Scope:select(...)
  if self._in_phase then
    -- Best-effort guard; helps catch illegal blocking inside install/hooks
    return false, "error"
  end
  local ops = {...}
  local n   = #ops
  if n == 0 then return false, "error" end

  -- Early cancel/deadline
  local now = monotime()
  if self.canceled then return false, self.cause end
  if self.deadline and now >= self.deadline then return false, "deadline" end

  -- 1) Poll phase (fast-path)
  local order = order_indices(n, self.policy, self._rr)
  for _, i in ipairs(order) do
    local ok_try, tr = try_pack(ops[i])
    if not ok_try then return false, "error" end
    if tr[1] then
      local rest = pack(unpack(tr, 2, tr.n))
      local ok_wrap, wr = wrap_pack(ops[i], rest)
      if not ok_wrap then return false, "error" end
      if self.policy == "fair" then self._rr = self._rr + 1 end
      return true, i, unpack(wr, 1, wr.n)
    end
  end

  -- 2) Install all branches
  local losers, commits = {}, {}
  local st = { done=false, idx=nil, values=nil, pending=nil, _sched=nil, _fib=nil, scause=nil }
  self._active[st] = true

  local install_err = false
  self._in_phase = true
  for i = 1, n do
    losers[i], commits[i] = {}, {}
    local ctx = {
      defer_loser  = function(fn) losers[i][#losers[i] + 1] = fn end,
      defer_commit = function(fn) commits[i][#commits[i]+1] = fn end,
    }
    local ok, _ = pcall(function()
      ops[i]:_install_call(ctx, make_susp(st, i))
    end)
    if not ok then install_err = true end
  end
  self._in_phase = false

  -- 2a) Winner completed during install
  if st.done and st.idx and st.idx ~= 0 then
    self._active[st] = nil
    for j = 1, n do if j ~= st.idx then run_hooks(losers[j]) end end
    run_hooks(commits[st.idx])
    local ok_wrap, wr = wrap_pack(ops[st.idx], st.values or pack())
    if not ok_wrap then return false, "error" end
    if self.policy == "fair" then self._rr = self._rr + 1 end
    return true, st.idx, unpack(wr, 1, wr.n)
  end

  -- 2b) Install error with no winner
  if install_err and not st.done then
    self._active[st] = nil
    for i = 1, n do run_hooks(losers[i]) end
    return false, "error"
  end

  -- 3) Arm per-select deadline (does not cancel the whole scope)
  if self.deadline and not self.canceled then
    local dt = self.deadline - monotime()
    if dt <= 0 and not st.done then
      st.done = true; st.scause = "deadline"
      st.pending = { idx = 0, values = pack() }
    elseif dt > 0 then
      fiber.current_scheduler:schedule_after_sleep(dt, {
        run = function()
          if st.done or self._active[st] == nil then return end
          st.done = true; st.scause = "deadline"
          if not st._sched or not st._fib then
            st.pending = { idx = 0, values = pack() }
          else
            st._sched:schedule({ run = function()
              st._fib:resume(function(i) st.idx = i end, 0)
            end })
          end
        end
      })
    end
  end

  -- 4) Block until completion
  local yielded = pack(fiber.suspend(block_select, st))
  local wrap_resume = yielded[1]
  if wrap_resume then wrap_resume(unpack(yielded, 2, yielded.n)) end

  -- clear active select marker
  self._active[st] = nil

  -- 5) Commit
  if st.idx == 0 or st.idx == nil then
    for i = 1, n do run_hooks(losers[i]) end
    return false, (st.scause or self.cause or "canceled")
  end

  local k = st.idx
  for j = 1, n do if j ~= k then run_hooks(losers[j]) end end
  run_hooks(commits[k])

  local ok_wrap, wr = wrap_pack(ops[k], st.values or pack())
  if not ok_wrap then return false, "error" end

  if self.policy == "fair" then self._rr = self._rr + 1 end
  return true, k, unpack(wr, 1, wr.n)
end

function Scope:wait(op_single)
  local pk = pack(self:select(op_single))        -- { ok, idx_or_cause, ... }
  if pk[1] then
    return true, unpack(pk, 3, pk.n)      -- drop idx on success
  else
    return false, pk[2]
  end
end

function Scope:any(list)
  return self:select(unpack(list))
end

-- Ambient accessor: returns the scope bound to the running fiber (or nil).
function Scope.current()
  return fiber.current_scope and fiber.current_scope() or nil
end

-- Spawn a child fiber *owned by this scope*. Non-throwing.
-- The child runs with this scope as its ambient current scope.
function Scope:spawn(fn)
  assert(type(fn) == "function", "Scope:spawn(fn): fn must be a function")
  self._wg:add(1)
  local child = { done = false, err = nil }
  table.insert(self._children, child)

  fiber._spawn_with_scope(self, function()
    local ok, err = pcall(fn, self) -- pass the scope for ergonomics
    child.done, child.err = true, (ok and nil or err)
    self._wg:done()
  end)
  return child
end

-- Wait for all Scope:spawn'ed children to complete. Non-throwing.
function Scope:join()
  self._wg:wait() -- returns when counter hits zero
  return true
end

return {
  new = new,
  current = Scope.current
}

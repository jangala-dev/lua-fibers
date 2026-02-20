-- fibers/channel.lua
--
-- Channel as Ops (targeted waking).
-- Supports unbuffered (capacity == 0) and buffered (capacity > 0) modes.

local runtime    = require 'fibers.runtime'
local op         = require 'fibers.op'
local List       = require 'fibers.utils.intrusive_list'
local fifo       = require 'fibers.utils.fifo'
local gate       = require 'fibers.choice_gate'
local rendezvous = require 'fibers.rendezvous'

local perform      = op.perform
local new_primitive = op.new_primitive

local Channel = {}
Channel.__index = Channel

function Channel.new(capacity)
  local rt = runtime.runtime
  if not rt.sched then error('runtime not initialised (call init(sched))', 2) end

  capacity = capacity or 0
  if type(capacity) ~= 'number' or capacity < 0 or capacity ~= math.floor(capacity) then
    error('Channel.new expects a non-negative integer capacity', 2)
  end

  return setmetatable({
    putq = List.new(),
    getq = List.new(),

    cap = capacity,
    buf = (capacity > 0) and fifo.new() or nil,

    -- increments on each committed pop; used to invalidate prepared buffered gets
    pop_seq = 0,
  }, Channel)
end

-- --------------------------------------------------------------------------
-- Queue scanning + waking
-- --------------------------------------------------------------------------

local function same_fibre_waker(self, ctx, what)
  if self.waker and self.waker ~= ctx.waker then
    error(('%s op used from a different fibre'):format(what), 0)
  end
  self.waker = ctx.waker
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
    if (not n.done) and (n.peer == nil) and gate.can_proceed(n.sel, n) then
      return n
    end
    n = n.next
  end
  return nil
end

local function wake_one_put(ch)
  local p = find_unmatched_put(ch.putq.head)
  if p then rendezvous.wake(p) end
end

local function wake_one_get(ch)
  local g = find_eligible_get(ch.getq.head)
  if g then rendezvous.wake(g) end
end

-- --------------------------------------------------------------------------
-- Rendezvous commit helper (shared spec; no per-call closures)
-- --------------------------------------------------------------------------

local function rv_unlink_put(p) p.ch.putq:unlink(p) end
local function rv_unlink_get(g) g.ch.getq:unlink(g) end
local function rv_transfer(p, g) g.result = p.val end
local function rv_after(_, g) g.sel = nil end

local RV_SPEC = {
  unlink_a = rv_unlink_put,
  unlink_b = rv_unlink_get,
  transfer = rv_transfer,
  after    = rv_after,
  wake     = "both",
}

local function commit_put_get(putop, getop)
  return rendezvous.commit(putop, getop, RV_SPEC)
end

-- --------------------------------------------------------------------------
-- Put op (primitive)
-- --------------------------------------------------------------------------

local function put_poll(self, ctx, out)
  local ch = self.ch

  if self.done then
    if out then out.n = 0 end
    return true
  end

  same_fibre_waker(self, ctx, 'put')

  -- Already paired: ready only once peer get has won (if in choice).
  local g = self.peer
  if g then
    if not gate.can_report_ready(g.sel, g) then
      return false
    end
    if out then out.n = 0 end
    return true
  end

  -- Rendezvous only if:
  --   * unbuffered, or
  --   * buffered but buffer empty (do not bypass buffered FIFO).
  if ch.cap == 0 or ch.buf:empty() then
    local r = find_eligible_get(ch.getq.head)
    if r then
      self.peer = r
      r.peer    = self
      rendezvous.wake(r)

      if not gate.can_report_ready(r.sel, r) then
        return false
      end

      if out then out.n = 0 end
      return true
    end
  end

  -- Buffered: ready if space.
  if ch.cap > 0 and ch.buf:length() < ch.cap then
    if out then out.n = 0 end
    return true
  end

  if not self.inq then
    ch.putq:push(self)
  end
  return false
end

local function put_commit(self, _ctx)
  if self.done then return end
  local ch = self.ch

  local g = self.peer
  if g then
    commit_put_get(self, g)
    return
  end

  if ch.cap > 0 then
    if self.inq then ch.putq:unlink(self) end

    if ch.buf:length() >= ch.cap then
      error('put.commit: buffer unexpectedly full', 0)
    end

    ch.buf:push(self.val)

    self.done  = true
    self.waker = nil

    -- New item available.
    wake_one_get(ch)
    return
  end

  error('put.commit: unreachable', 0)
end

local function put_rollback(self, _ctx, _why)
  if self.done then return end
  local ch = self.ch

  local g = self.peer
  if g and (not g.done) then
    rendezvous.detach(self, g, { wake = "both" })
  end

  self.peer  = nil
  self.waker = nil
  if self.inq then ch.putq:unlink(self) end
end

function Channel:put_op(val)
  return new_primitive(put_poll, put_commit, put_rollback, {
    ch   = self,
    val  = val,

    waker = nil,
    peer  = nil,
    done  = false,

    prev = nil,
    next = nil,
    inq  = false,
  })
end

-- --------------------------------------------------------------------------
-- Get op (primitive)
-- --------------------------------------------------------------------------

local function get_poll(self, ctx, out)
  local ch = self.ch

  if self.done then
    if out then
      out.n = 1
      out[1] = self.result
    end
    return true
  end

  same_fibre_waker(self, ctx, 'get')

  self.sel = gate.sel_from_ctx(ctx)
  if not gate.can_proceed(self.sel, self) then
    return false
  end

  -- Prepared revalidation across yield.
  if self.prepared then
    if self.prep_kind == 'peer' then
      local p = self.peer
      if (not p) or p.done or (p ~= self.prep_peer) or (p.val ~= self.prep_val) then
        return false
      end

      if self.sel and not gate.claim(self.sel, self) then
        return false
      end

      rendezvous.wake(p)

      if out then
        out.n = 1
        out[1] = self.prep_val
      end
      return true

    elseif self.prep_kind == 'buf' then
      if ch.buf:empty() then return false end
      if ch.pop_seq ~= self.prep_seq then return false end
      if ch.buf.first ~= self.prep_first then return false end

      if self.sel and not gate.claim(self.sel, self) then
        return false
      end

      if out then
        out.n = 1
        out[1] = ch.buf:peek() -- may be nil
      end
      return true

    else
      return false
    end
  end

  -- Buffered: drain buffer first (FIFO).
  if ch.cap > 0 and (not ch.buf:empty()) then
    if self.sel and not gate.claim(self.sel, self) then
      return false
    end

    if out then
      self.prepared   = true
      self.prep_kind  = 'buf'
      self.prep_seq   = ch.pop_seq
      self.prep_first = ch.buf.first
      self.prep_val   = ch.buf:peek()

      out.n = 1
      out[1] = self.prep_val
    end
    return true
  end

  -- Existing peer.
  local p = self.peer
  if p then
    if self.sel and not gate.claim(self.sel, self) then
      return false
    end

    rendezvous.wake(p)

    if out then
      self.prepared  = true
      self.prep_kind = 'peer'
      self.prep_val  = p.val
      self.prep_peer = p

      out.n = 1
      out[1] = self.prep_val
    end
    return true
  end

  -- Buffer empty: rendezvous with a waiting put.
  local s = find_unmatched_put(ch.putq.head)
  if s then
    if self.sel and not gate.claim(self.sel, self) then
      return false
    end

    self.peer = s
    s.peer    = self
    rendezvous.wake(s)

    if out then
      self.prepared  = true
      self.prep_kind = 'peer'
      self.prep_val  = s.val
      self.prep_peer = s

      out.n = 1
      out[1] = self.prep_val
    end
    return true
  end

  if not self.inq then
    ch.getq:push(self)
  end
  return false
end

local function get_commit(self, _ctx)
  if self.done then return self.result end
  local ch = self.ch

  local p = self.peer
  if p then
    commit_put_get(p, self)

    self.prepared, self.prep_kind, self.prep_peer, self.prep_val = false, nil, nil, nil
    self.prep_seq, self.prep_first = 0, 0

    return self.result
  end

  if ch.cap > 0 then
    if self.inq then ch.getq:unlink(self) end

    if ch.buf:empty() then
      error('get.commit: buffer unexpectedly empty', 0)
    end

    local v = ch.buf:pop()
    ch.pop_seq = ch.pop_seq + 1

    self.result = v
    self.done   = true
    self.sel    = nil
    self.waker  = nil

    self.prepared, self.prep_kind, self.prep_peer, self.prep_val = false, nil, nil, nil
    self.prep_seq, self.prep_first = 0, 0

    -- Space freed.
    wake_one_put(ch)
    return self.result
  end

  error('get.commit: unreachable', 0)
end

local function get_rollback(self, _ctx, _why)
  if self.done then return end
  local ch = self.ch

  local p = self.peer
  if p and (not p.done) then
    rendezvous.detach(p, self, { wake = "both" })
  end

  self.peer  = nil
  self.sel   = nil
  self.waker = nil

  self.prepared  = false
  self.prep_kind = nil
  self.prep_peer = nil
  self.prep_val  = nil
  self.prep_seq  = 0
  self.prep_first = 0

  if self.inq then ch.getq:unlink(self) end
end

function Channel:get_op()
  return new_primitive(get_poll, get_commit, get_rollback, {
    ch = self,

    waker  = nil,
    peer   = nil,
    result = nil,
    done   = false,

    prepared  = false,
    prep_kind = nil,
    prep_peer = nil,
    prep_val  = nil,
    prep_seq  = 0,
    prep_first = 0,

    sel = nil,

    prev = nil,
    next = nil,
    inq  = false,
  })
end

-- --------------------------------------------------------------------------
-- Convenience API
-- --------------------------------------------------------------------------

function Channel:put(v) return perform(self:put_op(v)) end
function Channel:get()  return perform(self:get_op()) end

return {
  Channel = Channel,
  new     = Channel.new,
}

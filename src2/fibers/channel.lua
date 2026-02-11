-- fibers/channel.lua
--
-- Unbuffered channel as transactional tickets (targeted waking).

local runtime = require 'fibers.runtime'
local op      = require 'fibers.op'

local perform = op.perform

local Channel = {}
Channel.__index = Channel

local Put = {}
Put.__index = Put
op._mixin_base(Put)

local Get = {}
Get.__index = Get
op._mixin_base(Get)

function Channel.new()
  local rt = runtime.runtime
  if not rt.sched then error('runtime not initialised (call init(sched))', 2) end
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
    if out then out.n = 0 end
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
      return nil
    end
    if out then out.n = 0 end
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

    if out then out.n = 0 end
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

function Put:rollback(_, _)
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

function Channel:get_op()
  return setmetatable({
    ch = self,

    waker  = nil,
    peer   = nil,
    result = nil,
    done   = false,

    prepared = false,
    prep_val = nil,
    prep_peer = nil,

    sel = nil,

    prev = nil,
    next = nil,
    inq = false,
  }, Get)
end

function Get:poll(ctx, out)
  local ch = self.ch
  if self.done then
    if out then
      out.n = 1
      out[1] = self.result
    end
    return self
  end

  if self.waker and self.waker ~= ctx.waker then
    error('get ticket used from a different fibre', 0)
  end
  self.waker = ctx.waker
  self.sel   = ctx.select_top

  local sel = self.sel
  if sel and sel.winner and sel.winner ~= self then
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

    if out then
      out.n = 1
      out[1] = self.prep_val
    end
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
      out.n = 1
      out[1] = self.prep_val
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
      out.n = 1
      out[1] = self.prep_val
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

function Get:rollback(_, _)
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
function Channel:get()  return perform(self:get_op()) end

return {
  Channel = Channel,
  new = Channel.new,
}

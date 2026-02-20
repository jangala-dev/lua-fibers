-- fibers/io/poller/core.lua
--
-- Pulse-only poller core: fd readiness -> Pulse:signal()
-- Uses backend ops for low-level polling plus optional on_wait_change() hook
-- for incremental interest updates (epoll/kqueue style), including oneshot re-arm.

local List = require 'fibers.utils.intrusive_list'

local Poller = {}
Poller.__index = Poller

local function list_empty(l)
  return (not l) or l:empty()
end

local function signal_list(head)
  local n = head
  while n do
    n.fired = true
    local w = n.waker
    if w then w:signal() end
    n = n.next
  end
end

-- fd reference counting for rd/wr watchers
local function inc(set, cnt, fd)
  local c = (cnt[fd] or 0) + 1
  cnt[fd] = c
  if c == 1 then
    set[fd] = true
    return true -- transitioned 0 -> 1
  end
  return false
end

local function dec(set, cnt, fd)
  local c = (cnt[fd] or 0) - 1
  if c <= 0 then
    cnt[fd] = nil
    set[fd] = nil
    return true -- transitioned 1 -> 0
  end
  cnt[fd] = c
  return false
end

local function want_rd(self, fd)
  return self.rd_cnt[fd] ~= nil
end

local function want_wr(self, fd)
  return self.wr_cnt[fd] ~= nil
end

-- Backend subscription / re-arm hook (optional).
-- Called:
--   * when interest changes (0->1 or 1->0 transitions), and
--   * after delivering events for an fd (oneshot re-arm).
local function update_backend(self, fd)
  local ops = self._ops
  local f = ops and ops.on_wait_change
  if not f then return end
  f(self.backend, fd, want_rd(self, fd), want_wr(self, fd))
end

function Poller.new(ops)
  assert(type(ops) == 'table', 'ops must be a table')
  assert(type(ops.new_backend) == 'function', 'ops.new_backend must be a function')
  assert(type(ops.poll) == 'function', 'ops.poll must be a function')

  return setmetatable({
    _ops     = ops,
    backend  = ops.new_backend(),

    rd_set = {}, wr_set = {},
    rd_cnt = {}, wr_cnt = {},

    rd = {}, wr = {},

    watchers = 0,
  }, Poller)
end

function Poller:has_watchers()
  return self.watchers > 0
end

function Poller:watch(fd, dir, waker)
  assert(fd ~= nil, 'fd must be non-nil')
  assert(dir == 'rd' or dir == 'wr', "dir must be 'rd' or 'wr'")
  assert(type(waker) == 'table' and type(waker.signal) == 'function', 'waker must be a Pulse')

  local node = {
    fd    = fd,
    dir   = dir,
    waker = waker,
    fired = false,
    inq   = false,

    -- intrusive list fields are expected by List
    prev = nil,
    next = nil,
  }

  local transitioned
  if dir == 'rd' then
    local l = self.rd[fd]
    if not l then
      l = List.new()
      self.rd[fd] = l
    end
    l:push(node)
    node.inq = true
    transitioned = inc(self.rd_set, self.rd_cnt, fd)
  else
    local l = self.wr[fd]
    if not l then
      l = List.new()
      self.wr[fd] = l
    end
    l:push(node)
    node.inq = true
    transitioned = inc(self.wr_set, self.wr_cnt, fd)
  end

  -- If interest changed for this fd, update backend subscription.
  if transitioned then
    update_backend(self, fd)
  else
    -- Even if this particular direction did not transition 0->1, the fd’s
    -- overall interest may have changed (e.g. first wr added while rd already
    -- had watchers). That case still yields transitioned==true for wr, so the
    -- above path covers it. No further action needed here.
  end

  self.watchers = self.watchers + 1
  return node
end

function Poller:cancel(node)
  if not node then return end

  -- Idempotent: clear observable state.
  node.waker = nil
  node.fired = false

  if not node.inq then
    return
  end

  local fd, dir = node.fd, node.dir
  local transitioned

  if dir == 'rd' then
    local l = self.rd[fd]
    if l then l:unlink(node) end
    node.inq = false

    transitioned = dec(self.rd_set, self.rd_cnt, fd)
    if transitioned then
      -- Drop empty list table when no watchers remain.
      if list_empty(l) then self.rd[fd] = nil end
      update_backend(self, fd)
    end
  else
    local l = self.wr[fd]
    if l then l:unlink(node) end
    node.inq = false

    transitioned = dec(self.wr_set, self.wr_cnt, fd)
    if transitioned then
      if list_empty(l) then self.wr[fd] = nil end
      update_backend(self, fd)
    end
  end

  self.watchers = self.watchers - 1
end

function Poller:poll(timeout_ms)
  if self.watchers == 0 then return end

  local events = self._ops.poll(self.backend, timeout_ms, self.rd_set, self.wr_set)
  if not events then return end

  for fd, flags in pairs(events) do
    if flags.err or flags.rd then
      local l = self.rd[fd]
      if l then signal_list(l.head) end
    end
    if flags.err or flags.wr then
      local l = self.wr[fd]
      if l then signal_list(l.head) end
    end

    -- Re-arm / refresh backend interest after delivering events.
    -- This is required for oneshot-style backends (e.g. EPOLLONESHOT).
    update_backend(self, fd)
  end
end

function Poller:close()
  if self.backend and self._ops.close_backend then
    self._ops.close_backend(self.backend)
  end
  self.backend = nil
end

return { Poller = Poller, new = Poller.new }

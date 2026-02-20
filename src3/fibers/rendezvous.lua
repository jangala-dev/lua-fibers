-- fibers/rendezvous.lua
--
-- Reusable rendezvous mechanics:
--   * pairing via node.peer (tentative)
--   * detach on rollback (clears peer links and wakes as configured)
--   * commit: mark done, transfer payload, unlink, cleanup, wake as configured
--
-- Nodes are expected to have: peer, done, waker, prev, next, inq
--
-- opts fields (all optional):
--   unlink_a(node) / unlink_b(node)     -- remove from wait-queue(s)
--   transfer(a, b)                      -- payload transfer / side effects
--   after(a, b)                         -- post-unlink cleanup (e.g. clear sel)
--   wake = "both"|"a"|"b"|"none"|fn     -- wake policy (default "both")
--   clear_waker = boolean               -- default true
--   clear_peer  = boolean               -- default true

local M = {}

local function default_unlink(_) end

local function wake_node(node)
  local w = node and node.waker
  if w then w:signal() end
end
M.wake = wake_node

local function do_wake(a, b, wake)
  if wake == "none" then
    return
  elseif wake == "a" then
    wake_node(a)
  elseif wake == "b" then
    wake_node(b)
  elseif type(wake) == "function" then
    wake(a, b)
  else
    -- default: both
    wake_node(a)
    wake_node(b)
  end
end

function M.detach(a, b, opts)
  opts = opts or {}
  local clear_peer = (opts.clear_peer ~= false)
  local wake = opts.wake or "both"

  if clear_peer then
    if a.peer == b then a.peer = nil end
    if b.peer == a then b.peer = nil end
  end

  do_wake(a, b, wake)
end

-- Returns true if commit occurred, false if either side was already done.
function M.commit(a, b, opts)
  opts = opts or {}

  if a.done or b.done then
    return false
  end

  a.done = true
  b.done = true

  local transfer = opts.transfer
  if transfer then
    transfer(a, b)
  end

  local unlink_a = opts.unlink_a or default_unlink
  local unlink_b = opts.unlink_b or default_unlink
  unlink_a(a)
  unlink_b(b)

  local clear_peer = (opts.clear_peer ~= false)
  if clear_peer then
    if a.peer == b then a.peer = nil end
    if b.peer == a then b.peer = nil end
  end

  local after = opts.after
  if after then
    after(a, b)
  end

  local clear_waker = (opts.clear_waker ~= false)
  local aw, bw
  if clear_waker then
    aw, bw = a.waker, b.waker
    a.waker, b.waker = nil, nil
  else
    aw, bw = a.waker, b.waker
  end

  local wake = opts.wake or "both"
  if wake == "none" then
    return true
  elseif wake == "a" then
    if aw then aw:signal() end
  elseif wake == "b" then
    if bw then bw:signal() end
  elseif type(wake) == "function" then
    wake(a, b)
  else
    if aw then aw:signal() end
    if bw then bw:signal() end
  end

  return true
end

return M

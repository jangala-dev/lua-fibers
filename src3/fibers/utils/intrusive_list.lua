-- fibers/utils/intrusive_list.lua
--
-- Minimal intrusive doubly-linked list.
--
-- Nodes must have:
--   prev : node|nil
--   next : node|nil
--   inq  : boolean   -- true iff the node is currently linked into this list
--
-- Conventions:
--   * push/unlink are idempotent.
--   * unlink always clears prev/next/inq.
--   * Iteration is not stable under mutation.

local List = {}
List.__index = List

function List.new()
  return setmetatable({ head = nil, tail = nil }, List)
end

function List:empty()
  return self.head == nil
end

function List:peek_head()
  return self.head
end

function List:peek_tail()
  return self.tail
end

-- Push onto the tail (FIFO-style). This preserves your existing API.
function List:push_tail(n)
  if not n or n.inq then return end
  local t = self.tail
  n.prev, n.next, n.inq = t, nil, true
  if t then t.next = n else self.head = n end
  self.tail = n
end

-- Backwards-compatible name.
List.push = List.push_tail

-- Push onto the head (stack/LIFO-style).
function List:push_head(n)
  if not n or n.inq then return end
  local h = self.head
  n.prev, n.next, n.inq = nil, h, true
  if h then h.prev = n else self.tail = n end
  self.head = n
end

function List:unlink(n)
  if not n or not n.inq then return end
  local p, nx = n.prev, n.next
  if p then p.next = nx else self.head = nx end
  if nx then nx.prev = p else self.tail = p end
  n.prev, n.next, n.inq = nil, nil, false
end

function List:pop_head_node()
  local h = self.head
  if not h then return nil end
  self:unlink(h)
  return h
end

function List:pop_tail_node()
  local t = self.tail
  if not t then return nil end
  self:unlink(t)
  return t
end

-- Clear the list (unlinks all nodes).
function List:clear()
  local n = self.head
  while n do
    local nx = n.next
    n.prev, n.next, n.inq = nil, nil, false
    n = nx
  end
  self.head, self.tail = nil, nil
end

-- Forward iterator: for n in list:iter() do ... end
-- Unsafe if you mutate the list during iteration.
function List:iter()
  local cur = nil
  return function()
    cur = (cur == nil) and self.head or cur.next
    return cur
  end
end

return {
  List = List,
  new  = List.new,
}

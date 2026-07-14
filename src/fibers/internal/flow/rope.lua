-- Persistent measured byte deque for Flow reservoirs.
--
-- Rope objects are mutable cursors over immutable chunk nodes.  clone() is
-- constant-time and speculative branches share all byte storage; append,
-- prepend and prefix consumption only replace cursor roots.

local Rope = {}
Rope.__index = Rope

local function node(chunk, next_)
  return { chunk = chunk, next = next_ }
end

local function reverse_nodes(xs)
  local out = nil
  while xs do
    out = node(xs.chunk, out)
    xs = xs.next
  end
  return out
end

local function ensure_front(self)
  if self.front or not self.back then
    return
  end
  self.front = reverse_nodes(self.back)
  self.front_count, self.back_count = self.back_count, 0
  self.back = nil
end

function Rope.new(data)
  local r =
    setmetatable({ front = nil, back = nil, head_off = 0, len = 0, front_count = 0, back_count = 0 }, Rope)
  if data and data ~= '' then
    r:append(data)
  end
  return r
end

function Rope.is(x)
  return getmetatable(x) == Rope
end

function Rope:clone()
  return setmetatable({
    front = self.front,
    back = self.back,
    head_off = self.head_off,
    len = self.len,
    front_count = self.front_count,
    back_count = self.back_count,
  }, Rope)
end

function Rope:length()
  return self.len
end
function Rope:is_empty()
  return self.len == 0
end
function Rope:chunk_count()
  return self.len == 0 and 0 or self.front_count + self.back_count
end

function Rope:reset()
  self.front, self.back, self.head_off, self.len = nil, nil, 0, 0
  self.front_count, self.back_count = 0, 0
end

function Rope:append(s)
  assert(type(s) == 'string', 'Rope:append expects a string')
  if s == '' then
    return self
  end
  self.back = node(s, self.back)
  self.back_count = self.back_count + 1
  self.len = self.len + #s
  return self
end

function Rope:prepend(s)
  assert(type(s) == 'string', 'Rope:prepend expects a string')
  if s == '' then
    return self
  end
  ensure_front(self)
  local front = self.front
  if front and self.head_off > 0 then
    front = node(front.chunk:sub(self.head_off + 1), front.next)
  end
  self.front = node(s, front)
  self.front_count = self.front_count + 1
  self.head_off = 0
  self.len = self.len + #s
  return self
end

function Rope:take(n)
  assert(type(n) == 'number' and n >= 0, 'Rope:take expects non-negative count')
  if n == 0 or self.len == 0 then
    return ''
  end
  if n > self.len then
    n = self.len
  end
  local out, need = {}, n
  while need > 0 do
    ensure_front(self)
    local first = self.front
    local available = #first.chunk - self.head_off
    local amount = math.min(need, available)
    out[#out + 1] = first.chunk:sub(self.head_off + 1, self.head_off + amount)
    need = need - amount
    if amount == available then
      self.front, self.head_off = first.next, 0
      self.front_count = self.front_count - 1
    else
      self.head_off = self.head_off + amount
    end
  end
  self.len = self.len - n
  if self.len == 0 then
    self:reset()
  end
  return table.concat(out)
end

local function append_visible(out, self, limit)
  local need, first = limit, true
  local cur = self.front
  while cur and need > 0 do
    local off = first and self.head_off or 0
    first = false
    local amount = math.min(need, #cur.chunk - off)
    out[#out + 1] = cur.chunk:sub(off + 1, off + amount)
    need = need - amount
    cur = cur.next
  end
  if need > 0 and self.back then
    local xs, n = {}, 0
    cur = self.back
    while cur do
      n = n + 1
      xs[n] = cur.chunk
      cur = cur.next
    end
    for i = n, 1, -1 do
      if need <= 0 then
        break
      end
      local amount = math.min(need, #xs[i])
      out[#out + 1] = xs[i]:sub(1, amount)
      need = need - amount
    end
  end
end

function Rope:peek(n)
  assert(type(n) == 'number' and n >= 0, 'Rope:peek expects non-negative count')
  if n == 0 or self.len == 0 then
    return ''
  end
  n = math.min(n, self.len)
  local out = {}
  append_visible(out, self, n)
  return table.concat(out)
end

function Rope:tostring()
  if self.len == 0 then
    return ''
  end
  local out = {}
  append_visible(out, self, self.len)
  return table.concat(out)
end

function Rope:find(pattern)
  assert(type(pattern) == 'string' and pattern ~= '', 'Rope:find expects non-empty string')
  local pos = self:tostring():find(pattern, 1, true)
  return pos and pos - 1 or nil
end

function Rope:inspect()
  return { length = self.len, chunk_count = self:chunk_count(), data = self:tostring() }
end

return Rope

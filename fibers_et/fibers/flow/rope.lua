-- Pure Lua byte rope for Flow reservoirs.
--
-- This is a small unbounded chunk queue, adapted from the old fibers byte
-- buffers.  It keeps appended byte chunks separate, supports efficient front
-- consumption, and materialises to a string only for observation or host calls.

local Rope = {}
Rope.__index = Rope

local function compact(self)
  local hi = self.head_idx
  if hi <= 8 and hi <= (#self.chunks / 2) then return end
  for i = 1, hi - 1 do self.chunks[i] = nil end
  local k = 1
  for j = hi, #self.chunks do
    self.chunks[k] = self.chunks[j]
    if k ~= j then self.chunks[j] = nil end
    k = k + 1
  end
  self.head_idx = 1
end

local function live_chunk_count(self)
  if self.len <= 0 then return 0 end
  return #self.chunks - self.head_idx + 1
end

function Rope.new(data)
  local r = setmetatable({ chunks = {}, head_idx = 1, head_off = 0, len = 0 }, Rope)
  if data and data ~= '' then r:append(data) end
  return r
end

function Rope.is(x) return getmetatable(x) == Rope end

function Rope:clone()
  local chunks = {}
  for i = 1, #self.chunks do chunks[i] = self.chunks[i] end
  return setmetatable({ chunks = chunks, head_idx = self.head_idx, head_off = self.head_off, len = self.len }, Rope)
end

function Rope:length() return self.len end
function Rope:is_empty() return self.len == 0 end
function Rope:chunk_count() return live_chunk_count(self) end

function Rope:reset()
  self.chunks = {}
  self.head_idx = 1
  self.head_off = 0
  self.len = 0
end

function Rope:append(s)
  assert(type(s) == 'string', 'Rope:append expects a string')
  if s == '' then return end
  self.chunks[#self.chunks + 1] = s
  self.len = self.len + #s
end

function Rope:prepend(s)
  assert(type(s) == 'string', 'Rope:prepend expects a string')
  if s == '' then return end
  if self.len == 0 then
    self.chunks = { s }
    self.head_idx = 1
    self.head_off = 0
    self.len = #s
    return
  end
  -- Keep return-to-front semantics simple and correct even when the current
  -- head chunk has a non-zero offset.
  local tail = self:tostring()
  self.chunks = { s, tail }
  self.head_idx = 1
  self.head_off = 0
  self.len = #s + #tail
end

function Rope:take(n)
  assert(type(n) == 'number' and n >= 0, 'Rope:take expects non-negative count')
  if n == 0 or self.len == 0 then return '' end
  if n > self.len then n = self.len end

  local out, need = {}, n
  local i, off, last = self.head_idx, self.head_off, #self.chunks
  while need > 0 and i <= last do
    local chunk = self.chunks[i]
    local rem = #chunk - off
    local take = math.min(need, rem)
    out[#out + 1] = chunk:sub(off + 1, off + take)
    need = need - take
    if take == rem then
      i = i + 1
      off = 0
    else
      off = off + take
    end
  end

  self.head_idx = i
  self.head_off = off
  self.len = self.len - n
  if self.len == 0 then self:reset() else compact(self) end
  return table.concat(out)
end

function Rope:peek(n)
  assert(type(n) == 'number' and n >= 0, 'Rope:peek expects non-negative count')
  if n == 0 or self.len == 0 then return '' end
  if n > self.len then n = self.len end

  local out, need = {}, n
  local i, off, last = self.head_idx, self.head_off, #self.chunks
  while need > 0 and i <= last do
    local chunk = self.chunks[i]
    local rem = #chunk - off
    local take = math.min(need, rem)
    out[#out + 1] = chunk:sub(off + 1, off + take)
    need = need - take
    if take == rem then
      i = i + 1
      off = 0
    else
      off = off + take
    end
  end
  return table.concat(out)
end

function Rope:tostring()
  if self.len == 0 then return '' end
  local out = {}
  local i, off, last = self.head_idx, self.head_off, #self.chunks
  if i <= last then
    local first = self.chunks[i]
    if off > 0 then first = first:sub(off + 1) end
    out[#out + 1] = first
    for j = i + 1, last do out[#out + 1] = self.chunks[j] end
  end
  return table.concat(out)
end

function Rope:find(pattern)
  assert(type(pattern) == 'string' and pattern ~= '', 'Rope:find expects non-empty string')
  local pos = self:tostring():find(pattern, 1, true)
  return pos and (pos - 1) or nil
end

function Rope:inspect()
  return { length = self.len, chunk_count = self:chunk_count(), data = self:tostring() }
end

return Rope

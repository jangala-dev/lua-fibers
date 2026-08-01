-- Persistent byte deque with incremental delimiter search.

local Rope = {}
Rope.__index = Rope

local MAX_SEARCHES = 16

local function node(bytes, next)
  return { bytes = bytes, next = next }
end

local function reverse(list)
  local out
  while list do
    out = node(list.bytes, out)
    list = list.next
  end
  return out
end

local function prefix_table(pattern)
  local prefix, matched = { [1] = 0 }, 0
  for i = 2, #pattern do
    local byte = pattern:sub(i, i)
    while matched > 0 and pattern:sub(matched + 1, matched + 1) ~= byte do
      matched = prefix[matched]
    end
    if pattern:sub(matched + 1, matched + 1) == byte then
      matched = matched + 1
    end
    prefix[i] = matched
  end
  return prefix
end

local function copy_array(values)
  local out = {}
  for i = 1, #values do out[i] = values[i] end
  return out
end

local function copy_searches(searches)
  local out = {}
  for pattern, search in pairs(searches) do
    out[pattern] = {
      pattern = search.pattern,
      prefix = search.prefix,
      matched = search.matched,
      scanned = search.scanned,
      match = search.match,
    }
  end
  return out
end

local function feed(search, bytes, base)
  if search.match ~= nil or bytes == '' then return end
  local pattern, prefix, matched = search.pattern, search.prefix, search.matched
  for i = 1, #bytes do
    local byte = bytes:sub(i, i)
    while matched > 0 and pattern:sub(matched + 1, matched + 1) ~= byte do
      matched = prefix[matched]
    end
    if pattern:sub(matched + 1, matched + 1) == byte then
      matched = matched + 1
    end
    if matched == #pattern then
      search.match = base + i - #pattern
      search.matched = matched
      search.scanned = base + i
      return
    end
  end
  search.matched = matched
  search.scanned = base + #bytes
end

local function each(self, visit)
  local first, current = true, self.front
  while current do
    local offset = first and self.offset or 0
    first = false
    local bytes = current.bytes:sub(offset + 1)
    if bytes ~= '' then visit(bytes) end
    current = current.next
  end

  local back = {}
  current = self.back
  while current do
    back[#back + 1] = current.bytes
    current = current.next
  end
  for i = #back, 1, -1 do visit(back[i]) end
end

local function clear_searches(self)
  self.searches, self.search_order = {}, {}
end

local function touch(self, pattern)
  for i = 1, #self.search_order do
    if self.search_order[i] == pattern then
      table.remove(self.search_order, i)
      break
    end
  end
  self.search_order[#self.search_order + 1] = pattern
end

local function cache(self, pattern, search)
  if #self.search_order >= MAX_SEARCHES then
    self.searches[table.remove(self.search_order, 1)] = nil
  end
  self.searches[pattern] = search
  self.search_order[#self.search_order + 1] = pattern
end

local function ensure_front(self)
  if self.front or not self.back then return end
  self.front, self.back = reverse(self.back), nil
end

local function search_for(self, pattern)
  local search = self.searches[pattern]
  if search then
    touch(self, pattern)
    return search
  end

  search = { pattern = pattern, prefix = prefix_table(pattern), matched = 0, scanned = 0 }
  local base = 0
  each(self, function(bytes)
    if search.match == nil then feed(search, bytes, base) end
    base = base + #bytes
  end)
  cache(self, pattern, search)
  return search
end

function Rope.new(bytes)
  local rope = setmetatable({
    front = nil,
    back = nil,
    offset = 0,
    len = 0,
    searches = {},
    search_order = {},
  }, Rope)
  if bytes and bytes ~= '' then rope:append(bytes) end
  return rope
end

function Rope:clone()
  return setmetatable({
    front = self.front,
    back = self.back,
    offset = self.offset,
    len = self.len,
    searches = copy_searches(self.searches),
    search_order = copy_array(self.search_order),
  }, Rope)
end

function Rope:length()
  return self.len
end

function Rope:is_empty()
  return self.len == 0
end

function Rope:append(bytes)
  assert(type(bytes) == 'string', 'Rope:append expects a string')
  if bytes == '' then return self end
  local base = self.len
  for _, search in pairs(self.searches) do feed(search, bytes, base) end
  self.back = node(bytes, self.back)
  self.len = self.len + #bytes
  return self
end

function Rope:prepend(bytes)
  assert(type(bytes) == 'string', 'Rope:prepend expects a string')
  if bytes == '' then return self end
  clear_searches(self)
  ensure_front(self)
  local front = self.front
  if front and self.offset > 0 then
    front = node(front.bytes:sub(self.offset + 1), front.next)
  end
  self.front = node(bytes, front)
  self.offset = 0
  self.len = self.len + #bytes
  return self
end

function Rope:take(n)
  assert(type(n) == 'number' and n >= 0 and n % 1 == 0, 'Rope:take expects a non-negative integer')
  n = math.min(n, self.len)
  if n == 0 then return '' end

  clear_searches(self)
  local out, remaining = {}, n
  while remaining > 0 do
    ensure_front(self)
    local first = self.front
    local available = #first.bytes - self.offset
    local amount = math.min(remaining, available)
    out[#out + 1] = first.bytes:sub(self.offset + 1, self.offset + amount)
    remaining = remaining - amount
    if amount == available then
      self.front, self.offset = first.next, 0
    else
      self.offset = self.offset + amount
    end
  end

  self.len = self.len - n
  if self.len == 0 then
    self.front, self.back, self.offset = nil, nil, 0
  end
  return table.concat(out)
end

function Rope:peek(n)
  assert(type(n) == 'number' and n >= 0 and n % 1 == 0, 'Rope:peek expects a non-negative integer')
  local out, remaining = {}, math.min(n, self.len)
  each(self, function(bytes)
    if remaining > 0 then
      local amount = math.min(remaining, #bytes)
      out[#out + 1] = bytes:sub(1, amount)
      remaining = remaining - amount
    end
  end)
  return table.concat(out)
end

function Rope:find(pattern)
  assert(type(pattern) == 'string' and pattern ~= '', 'Rope:find expects a non-empty string')
  return search_for(self, pattern).match
end

function Rope:ends_with_prefix(pattern)
  assert(type(pattern) == 'string' and pattern ~= '', 'Rope:ends_with_prefix expects a non-empty string')
  local search = search_for(self, pattern)
  return search.match == nil and search.matched > 0
end

return Rope

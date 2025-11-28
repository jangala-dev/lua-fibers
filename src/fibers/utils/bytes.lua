-- fibers/utils/bytes.lua
--
-- Unified buffer abstraction:
--   * bytes.RingBuf   : ring buffer for bytes
--   * bytes.LinearBuf : growable linear buffer
--
-- Two implementations exist:
--   - FFI-backed (LuaJIT or lua-cffi) under bytes.ffi
--   - Pure Lua rope/string-based under bytes.lua
--
-- The default backend is chosen at load time:
--   _G.FIBERS_BYTES_BACKEND = "ffi" | "lua" | "auto" (default: "auto")
--   "auto" => use FFI if available, else pure Lua.
---@module 'fibers.utils.bytes'

local is_LuaJIT = rawget(_G, "jit") and true or false

local bit = rawget(_G, "bit") or require 'bit32'

local ok_ffi, ffi
if is_LuaJIT then
  ok_ffi, ffi = pcall(require, 'ffi')
else
  ok_ffi, ffi = pcall(require, 'cffi')
end

local has_ffi = ok_ffi and (ffi ~= nil)

----------------------------------------------------------------------
-- High-level type annotations
----------------------------------------------------------------------

--- Fixed-capacity byte ring buffer.
--- Implementations:
---   * FFI: C struct with power-of-two size and index masking.
---   * Lua: rope of strings with explicit size limit.
---@class RingBuf
---@field size integer                 # configured capacity
---@field len integer                  # unread byte count (Lua impl; FFI uses indices)
---@field buf any                      # FFI backing storage (uint8_t[]); Lua impl ignores
---@field read_avail fun(self: RingBuf): integer
---@field write_avail fun(self: RingBuf): integer
---@field is_empty fun(self: RingBuf): boolean
---@field is_full fun(self: RingBuf): boolean
---@field reset fun(self: RingBuf)
---@field put fun(self: RingBuf, s: string)           # enqueue bytes
---@field take fun(self: RingBuf, n: integer): string # dequeue up to n bytes
---@field tostring fun(self: RingBuf): string         # non-destructive snapshot
---@field find fun(self: RingBuf, pattern: string): integer|nil
---@field init fun(self: RingBuf, size: integer): RingBuf

--- Growable linear byte buffer.
---@class LinearBuf
---@field reset fun(self: LinearBuf)
---@field append fun(self: LinearBuf, s: string)
---@field tostring fun(self: LinearBuf): string

--- RingBuf constructor module.
---@class RingBufModule
---@field new fun(size: integer): RingBuf

--- LinearBuf constructor module.
---@class LinearBufModule
---@field new fun(size?: integer): LinearBuf

----------------------------------------------------------------------
-- FFI-backed implementation builder
----------------------------------------------------------------------

--- Build the FFI-backed implementation tables, if FFI is available.
---@return { RingBuf: RingBufModule, LinearBuf: LinearBufModule }|nil
local function build_ffi_impl()
  if not has_ffi then
    return nil
  end

  local band = bit.band

  -- Ring buffer struct: indices wrap modulo 2^32; size must be power of two.
  ffi.cdef[[
    typedef struct {
      uint32_t read_idx;
      uint32_t write_idx;
      uint32_t size;
      uint8_t  buf[?];
    } fibers_ringbuf_t;
  ]]

  ---@class FfiRingBuf : RingBuf
  local ring_mt = {}
  ring_mt.__index = ring_mt

  -- Linear buffer is implemented as a Lua table with a growable
  -- uint8_t[] backing store; no C struct is required.
  ---@class FfiLinearBuf : LinearBuf
  local lin_mt  = {}
  lin_mt.__index = lin_mt

  local ring_ct = ffi.metatype("fibers_ringbuf_t", ring_mt)

  --- Normalise to uint32 range for index arithmetic.
  ---@param n integer
  ---@return integer
  local function to_uint32(n)
    return n % 2^32
  end

  --------------------------------------------------------------------
  -- RingBuf (FFI)
  --------------------------------------------------------------------

  --- Initialise a ring buffer with a power-of-two size.
  ---@param size integer
  ---@return FfiRingBuf
  function ring_mt:init(size)
    assert(type(size) == "number" and size > 0, "RingBuf: positive size required")
    assert(band(size, size - 1) == 0, "RingBuf: size must be power of two")
    self.size      = size
    self.read_idx  = 0
    self.write_idx = 0
    return self
  end

  --- Reset indices; content is treated as discarded.
  function ring_mt:reset()
    self.read_idx  = 0
    self.write_idx = 0
  end

  --- Number of bytes available to read.
  ---@return integer
  function ring_mt:read_avail()
    return to_uint32(self.write_idx - self.read_idx)
  end

  --- Remaining capacity for writes.
  ---@return integer
  function ring_mt:write_avail()
    return self.size - self:read_avail()
  end

  function ring_mt:is_empty()
    return self.read_idx == self.write_idx
  end

  function ring_mt:is_full()
    return self:read_avail() == self.size
  end

  --- Internal: absolute read position modulo size.
  ---@return integer
  function ring_mt:_read_pos()
    return band(self.read_idx, self.size - 1)
  end

  --- Internal: absolute write position modulo size.
  ---@return integer
  function ring_mt:_write_pos()
    return band(self.write_idx, self.size - 1)
  end

  --- Advance read index by count bytes.
  ---@param count integer
  function ring_mt:advance_read(count)
    assert(count >= 0 and count <= self:read_avail(), "RingBuf:advance_read out of range")
    self.read_idx = self.read_idx + ffi.cast("uint32_t", count)
  end

  --- Advance write index by count bytes.
  ---@param count integer
  function ring_mt:advance_write(count)
    assert(count >= 0 and count <= self:write_avail(), "RingBuf:advance_write out of range")
    self.write_idx = self.write_idx + ffi.cast("uint32_t", count)
  end

  --- Low-level pointer-based write into the ring.
  ---@param src ffi.ct*  -- pointer to bytes
  ---@param count integer
  function ring_mt:write(src, count)
    assert(count >= 0 and count <= self:write_avail(), "RingBuf: write xrun")
    if count == 0 then return end
    local pos   = self:_write_pos()
    local size  = self.size
    local first = math.min(size - pos, count)
    if first > 0 then
      ffi.copy(self.buf + pos, src, first)
    end
    local rest = count - first
    if rest > 0 then
      ffi.copy(self.buf, src + first, rest)
    end
    self:advance_write(count)
  end

  --- Low-level pointer-based read from the ring.
  ---@param dst ffi.ct*  -- pointer to destination
  ---@param count integer
  function ring_mt:read(dst, count)
    assert(count >= 0 and count <= self:read_avail(), "RingBuf: read xrun")
    if count == 0 then return end
    local pos   = self:_read_pos()
    local size  = self.size
    local first = math.min(size - pos, count)
    if first > 0 then
      ffi.copy(dst, self.buf + pos, first)
    end
    local rest = count - first
    if rest > 0 then
      ffi.copy(dst + first, self.buf, rest)
    end
    self:advance_read(count)
  end

  --- Peek at contiguous readable bytes without advancing.
  ---@return ffi.ct*|nil ptr
  ---@return integer len
  function ring_mt:peek()
    local pos   = self:_read_pos()
    local avail = self:read_avail()
    local first = math.min(avail, self.size - pos)
    if first <= 0 then
      return nil, 0
    end
    return self.buf + pos, first
  end

  --- Reserve contiguous write space and return pointer and length.
  --- Caller must follow with commit(count) after writing.
  ---@param request? integer
  ---@return ffi.ct*|nil ptr
  ---@return integer len
  function ring_mt:reserve(request)
    local avail = self:write_avail()
    if avail <= 0 then
      return nil, 0
    end
    local pos   = self:_write_pos()
    local first = math.min(avail, self.size - pos)
    local n     = first
    if request and request < n then
      n = request
    end
    if n <= 0 then
      return nil, 0
    end
    return self.buf + pos, n
  end

  --- Commit count bytes previously reserved.
  ---@param count integer
  function ring_mt:commit(count)
    self:advance_write(count)
  end

  -- String-oriented helpers to match the pure Lua interface.

  --- Enqueue a string into the ring.
  ---@param str string
  function ring_mt:put(str)
    assert(type(str) == "string", "RingBuf:put expects a string")
    local n = #str
    if n == 0 then return end
    assert(n <= self:write_avail(), "RingBuf: write would exceed capacity")
    local tmp = ffi.new("uint8_t[?]", n)
    ffi.copy(tmp, str, n)
    self:write(tmp, n)
  end

  --- Dequeue up to n bytes and return as a string.
  ---@param n integer
  ---@return string
  function ring_mt:take(n)
    assert(type(n) == "number" and n >= 0, "RingBuf:take expects non-negative count")
    local avail = self:read_avail()
    if avail == 0 or n == 0 then
      return ""
    end
    if n > avail then
      n = avail
    end
    local tmp = ffi.new("uint8_t[?]", n)
    self:read(tmp, n)
    return ffi.string(tmp, n)
  end

  --- Non-destructive snapshot of all readable data as a string.
  --- Internally reads then rewinds read_idx.
  ---@return string
  function ring_mt:tostring()
    local n = self:read_avail()
    if n == 0 then
      return ""
    end
    local tmp = ffi.new("uint8_t[?]", n)
    self:read(tmp, n)
    -- Restore read_idx so this is a non-destructive view.
    self.read_idx = self.read_idx - ffi.cast("uint32_t", n)
    return ffi.string(tmp, n)
  end

  --- Find a literal substring in the readable region.
  --- Returns zero-based offset or nil.
  ---@param pattern string
  ---@return integer|nil
  function ring_mt:find(pattern)
    assert(type(pattern) == "string" and #pattern > 0, "RingBuf:find expects non-empty string")
    local s = self:tostring()
    local i = s:find(pattern, 1, true)
    return i and (i - 1) or nil
  end

  --------------------------------------------------------------------
  -- LinearBuf (FFI, growable)
  --
  -- Growable linear buffer backed by a uint8_t[] array.
  -- cap is treated as an initial capacity hint; the buffer grows
  -- geometrically when needed.
  --------------------------------------------------------------------

  --- Create a new FFI-backed LinearBuf.
  ---@param cap? integer
  ---@return FfiLinearBuf
  local function LinearBuf_new(cap)
    cap = cap or 4096
    assert(cap > 0, "LinearBuf.new: positive initial capacity required")
    local buf = ffi.new("uint8_t[?]", cap)
    return setmetatable({
      buf = buf,
      len = 0,
      cap = cap,
    }, lin_mt)
  end

  --- Reset to empty without releasing capacity.
  function lin_mt:reset()
    self.len = 0
  end

  --- Ensure space for at least extra bytes beyond current len.
  ---@param extra integer
  function lin_mt:ensure(extra)
    assert(extra >= 0, "LinearBuf:ensure expects non-negative extra")
    local needed = self.len + extra
    if needed <= self.cap then
      return
    end

    local new_cap = self.cap
    if new_cap <= 0 then
      new_cap = 1
    end
    while new_cap < needed do
      new_cap = new_cap * 2
    end

    local new_buf = ffi.new("uint8_t[?]", new_cap)
    if self.len > 0 then
      ffi.copy(new_buf, self.buf, self.len)
    end

    self.buf = new_buf
    self.cap = new_cap
  end

  --- Reserve raw space for n bytes and return a pointer.
  --- Caller must follow with commit(n) after writing.
  ---@param n integer
  ---@return ffi.ct* ptr
  function lin_mt:reserve(n)
    assert(type(n) == "number" and n >= 0, "LinearBuf:reserve expects non-negative count")
    if n == 0 then
      return self.buf + self.len
    end
    self:ensure(n)
    return self.buf + self.len
  end

  --- Commit n bytes written after reserve().
  ---@param n integer
  function lin_mt:commit(n)
    assert(type(n) == "number" and n >= 0, "LinearBuf:commit expects non-negative count")
    assert(self.len + n <= self.cap, "LinearBuf:commit overflow")
    self.len = self.len + n
  end

  --- Convert buffer contents to a string.
  ---@return string
  function lin_mt:tostring()
    if self.len == 0 then
      return ""
    end
    return ffi.string(self.buf, self.len)
  end

  --- String-level append matching the pure Lua interface.
  ---@param str string
  function lin_mt:append(str)
    assert(type(str) == "string", "LinearBuf:append expects a string")
    local n = #str
    if n == 0 then return end
    self:ensure(n)
    ffi.copy(self.buf + self.len, str, n)
    self.len = self.len + n
  end

  --------------------------------------------------------------------
  -- Public constructors (FFI)
  --------------------------------------------------------------------

  ---@class FfiImpl
  ---@field RingBuf RingBufModule
  ---@field LinearBuf LinearBufModule
  local ffi_impl = {}

  --- Create a new FFI-backed RingBuf.
  ---@param size integer
  ---@return RingBuf
  function ffi_impl.RingBuf_new(size)
    local self = ring_ct(size)
    return ring_mt.init(self, size)
  end

  ffi_impl.RingBuf = { new = ffi_impl.RingBuf_new }

  ffi_impl.LinearBuf_new = LinearBuf_new
  ffi_impl.LinearBuf     = { new = LinearBuf_new }

  return ffi_impl
end

----------------------------------------------------------------------
-- Pure Lua implementation builder
----------------------------------------------------------------------

--- Build the pure Lua implementation tables (no FFI).
---@return { RingBuf: RingBufModule, LinearBuf: LinearBufModule }
local function build_lua_impl()
  --------------------------------------------------------------------
  -- RingBuf (pure Lua, rope-style: table of strings)
  --------------------------------------------------------------------

  ---@class LuaRingBuf : RingBuf
  local RingBuf_mt = {}
  RingBuf_mt.__index = RingBuf_mt

  --- Create a new rope-based RingBuf with fixed capacity.
  ---@param size integer
  ---@return LuaRingBuf
  local function RingBuf_new(size)
    assert(type(size) == "number" and size > 0, "RingBuf.new: positive size required")
    return setmetatable({
      chunks   = {},  -- array of strings
      head_idx = 1,   -- index of first chunk with unread data
      head_off = 0,   -- bytes already consumed from chunks[head_idx]
      len      = 0,   -- total unread bytes
      size     = size,
    }, RingBuf_mt)
  end

  function RingBuf_mt:reset()
    self.chunks   = {}
    self.head_idx = 1
    self.head_off = 0
    self.len      = 0
  end

  function RingBuf_mt:read_avail()
    return self.len
  end

  function RingBuf_mt:write_avail()
    return self.size - self.len
  end

  function RingBuf_mt:is_empty()
    return self.len == 0
  end

  function RingBuf_mt:is_full()
    return self.len >= self.size
  end

  --- Compact the chunks array when the head index has advanced far.
  --- This keeps table size bounded over long runs.
  ---@param self LuaRingBuf
  local function compact(self)
    local hi = self.head_idx
    if hi <= 8 and hi <= (#self.chunks / 2) then
      return
    end
    for i = 1, hi - 1 do
      self.chunks[i] = nil
    end
    local k = 1
    for j = hi, #self.chunks do
      self.chunks[k] = self.chunks[j]
      if k ~= j then self.chunks[j] = nil end
      k = k + 1
    end
    self.head_idx = 1
  end

  --- Advance read position by n bytes.
  ---@param n integer
  function RingBuf_mt:advance_read(n)
    assert(n >= 0 and n <= self.len, "RingBuf:advance_read out of range")
    if n == 0 then return end

    self.len = self.len - n

    local i   = self.head_idx
    local off = self.head_off

    while n > 0 and i <= #self.chunks do
      local chunk = self.chunks[i]
      local rem   = #chunk - off
      if n < rem then
        off = off + n
        n   = 0
      else
        n   = n - rem
        i   = i + 1
        off = 0
      end
    end

    self.head_idx = i
    self.head_off = off
    compact(self)
  end

  --- Low-level write used internally (string-based).
  ---@param src string
  ---@param count? integer
  function RingBuf_mt:write(src, count)
    assert(type(src) == "string", "RingBuf:write expects string in pure Lua mode")
    local n = count or #src
    assert(n <= #src, "RingBuf:write count > #src")
    assert(n <= self:write_avail(), "RingBuf: write xrun")

    if n == 0 then return end
    local s = src
    if n < #s then
      s = s:sub(1, n)
    end
    self.len = self.len + n
    table.insert(self.chunks, s)
  end

  --- Low-level read used internally; returns a string of count bytes.
  ---@param _ any
  ---@param count integer
  ---@return string
  function RingBuf_mt:read(_, count)
    assert(count >= 0 and count <= self.len, "RingBuf: read xrun")
    if count == 0 then return "" end

    local out  = {}
    local need = count
    local i    = self.head_idx
    local off  = self.head_off
    local n    = #self.chunks

    while need > 0 and i <= n do
      local chunk = self.chunks[i]
      local rem   = #chunk - off
      local take  = math.min(need, rem)
      out[#out + 1] = chunk:sub(off + 1, off + take)
      need = need - take
      if take == rem then
        i   = i + 1
        off = 0
      else
        off = off + take
      end
    end

    local s = table.concat(out)
    self.head_idx = i
    self.head_off = off
    self.len      = self.len - count
    compact(self)
    return s
  end

  --- Peek at next chunk as a single string without advancing.
  ---@return string|nil chunk
  ---@return integer len
  function RingBuf_mt:peek()
    if self.len == 0 then
      return nil, 0
    end

    local i   = self.head_idx
    local off = self.head_off
    local chunk = self.chunks[i]
    local rem   = #chunk - off

    if rem <= 0 then
      return nil, 0
    end
    local s = chunk:sub(off + 1)
    return s, #s
  end

  --- Reserve space; not supported in Lua backend.
  ---@param _ any
  ---@return nil, integer
  function RingBuf_mt:reserve(_)
    return nil, 0
  end

  function RingBuf_mt:commit(_)
  end

  -- String-oriented helpers matching the FFI interface.

  --- Enqueue a string into the ring.
  ---@param str string
  function RingBuf_mt:put(str)
    assert(type(str) == "string", "RingBuf:put expects a string")
    local n = #str
    if n == 0 then return end
    assert(n <= self:write_avail(), "RingBuf: write would exceed capacity")
    self:write(str, n)
  end

  --- Dequeue up to n bytes and return as a string.
  ---@param n integer
  ---@return string
  function RingBuf_mt:take(n)
    assert(type(n) == "number" and n >= 0, "RingBuf:take expects non-negative count")
    if self.len == 0 or n == 0 then
      return ""
    end
    if n > self.len then
      n = self.len
    end
    return self:read(nil, n)
  end

  --- Non-destructive snapshot of all data.
  ---@return string
  function RingBuf_mt:tostring()
    if self.len == 0 then
      return ""
    end
    local out = {}
    local i   = self.head_idx
    local off = self.head_off
    local n   = #self.chunks

    if i <= n then
      local first = self.chunks[i]
      if off > 0 then
        first = first:sub(off + 1)
      end
      out[#out + 1] = first
      for j = i + 1, n do
        out[#out + 1] = self.chunks[j]
      end
    end

    return table.concat(out)
  end

  --- Find a literal substring in the readable region.
  --- Returns zero-based offset or nil.
  ---@param pattern string
  ---@return integer|nil
  function RingBuf_mt:find(pattern)
    assert(type(pattern) == "string" and #pattern > 0, "RingBuf:find expects non-empty string")
    local s = self:tostring()
    local i = s:find(pattern, 1, true)
    return i and (i - 1) or nil
  end

  --------------------------------------------------------------------
  -- LinearBuf (pure Lua, rope-style)
  --------------------------------------------------------------------

  ---@class LuaLinearBuf : LinearBuf
  local LinearBuf_mt = {}
  LinearBuf_mt.__index = LinearBuf_mt

  --- Create a new rope-based LinearBuf.
  ---@param _ integer
  ---@return LuaLinearBuf
  local function LinearBuf_new(_)
    return setmetatable({
      chunks   = {},
      head_idx = 1,
      head_off = 0,
      len      = 0,
    }, LinearBuf_mt)
  end

  function LinearBuf_mt:reset()
    self.chunks   = {}
    self.head_idx = 1
    self.head_off = 0
    self.len      = 0
  end

  --- Append a string to the linear buffer.
  ---@param s string
  function LinearBuf_mt:append(s)
    if not s or #s == 0 then return end
    self.len = self.len + #s
    table.insert(self.chunks, s)
  end

  --- Convert contents to a string.
  ---@return string
  function LinearBuf_mt:tostring()
    if self.len == 0 then
      return ""
    end
    local out = {}
    local i   = self.head_idx
    local off = self.head_off
    local n   = #self.chunks

    if i <= n then
      local first = self.chunks[i]
      if off > 0 then
        first = first:sub(off + 1)
      end
      out[#out + 1] = first
      for j = i + 1, n do
        out[#out + 1] = self.chunks[j]
      end
    end

    return table.concat(out)
  end

  --- Advance read position by n bytes, discarding data.
  ---@param n integer
  function LinearBuf_mt:advance(n)
    assert(n >= 0 and n <= self.len, "LinearBuf:advance out of range")
    if n == 0 then return end

    self.len = self.len - n
    local i   = self.head_idx
    local off = self.head_off

    while n > 0 and i <= #self.chunks do
      local chunk = self.chunks[i]
      local rem   = #chunk - off
      if n < rem then
        off = off + n
        n   = 0
      else
        n   = n - rem
        i   = i + 1
        off = 0
      end
    end

    self.head_idx = i
    self.head_off = off
  end

  function LinearBuf_mt:reserve(_)
    return nil
  end

  function LinearBuf_mt:commit(_)
  end

  ---@class LuaImpl
  ---@field RingBuf RingBufModule
  ---@field LinearBuf LinearBufModule
  local lua_impl = {
    RingBuf   = { new = RingBuf_new },
    LinearBuf = { new = LinearBuf_new },
  }

  return lua_impl
end

----------------------------------------------------------------------
-- Assemble implementations and choose default
----------------------------------------------------------------------

local ffi_impl = build_ffi_impl()
local lua_impl = build_lua_impl()

local backend = rawget(_G, "FIBERS_BYTES_BACKEND") or "auto"

local use_ffi
if backend == "ffi" then
  use_ffi = (ffi_impl ~= nil)
elseif backend == "lua" then
  use_ffi = false
else -- "auto"
  use_ffi = (ffi_impl ~= nil)
end

local impl = use_ffi and ffi_impl or lua_impl

---@class BytesModule
---@field RingBuf RingBufModule
---@field LinearBuf LinearBufModule
---@field has_ffi boolean
---@field ffi { RingBuf: RingBufModule, LinearBuf: LinearBufModule }|nil
---@field lua { RingBuf: RingBufModule, LinearBuf: LinearBufModule }

local M_out = {
  -- Default backend:
  RingBuf   = impl.RingBuf,
  LinearBuf = impl.LinearBuf,
  has_ffi   = use_ffi,

  -- Explicit backends for testing / overrides:
  ffi = ffi_impl,
  lua = lua_impl,
}

return M_out

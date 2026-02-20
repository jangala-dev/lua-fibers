-- fibers/utils/bytes/ffi.lua
--
-- FFI-backed byte buffers:
--   * RingBuf   : fixed-capacity ring buffer
--   * LinearBuf : growable buffer with read offset (no per-advance memmove)

---@module 'fibers.utils.bytes.ffi'

local bit   = rawget(_G, 'bit') or require 'bit32'
local ffi_c = require 'fibers.utils.ffi_compat'

-- If there is no usable FFI layer, mark this backend unsupported.
if not (ffi_c.is_supported and ffi_c.is_supported()) then
	return {
		is_supported = function () return false end,
	}
end

local ffi  = ffi_c.ffi
local band = bit.band

ffi.cdef [[
  typedef unsigned int   uint32_t;
  typedef unsigned char  uint8_t;

  typedef struct {
    uint32_t read_idx;
    uint32_t write_idx;
    uint32_t size;
    uint8_t  buf[?];
  } fibers_ringbuf_t;
]]

local ring_mt, lin_mt = {}, {}
ring_mt.__index       = ring_mt
lin_mt.__index        = lin_mt

local ring_ct = ffi.metatype('fibers_ringbuf_t', ring_mt)

local function to_u32(n)
	return n % 2 ^ 32
end

local function pos(self, idx)
	return band(idx, self.size - 1)
end

----------------------------------------------------------------------
-- RingBuf
----------------------------------------------------------------------

--- Initialise ring buffer.
function ring_mt:init(size)
	assert(type(size) == 'number' and size > 0, 'RingBuf: positive size required')
	assert(band(size, size - 1) == 0, 'RingBuf: size must be power of two')
	self.size      = size
	self.read_idx  = 0
	self.write_idx = 0
	return self
end

function ring_mt:reset()
	self.read_idx, self.write_idx = 0, 0
end

function ring_mt:read_avail()
	return to_u32(self.write_idx - self.read_idx)
end

function ring_mt:write_avail()
	return self.size - self:read_avail()
end

function ring_mt:is_empty()
	return self.read_idx == self.write_idx
end

function ring_mt:is_full()
	return self:read_avail() == self.size
end

local function copy_out(self, n)
	local tmp   = ffi.new('uint8_t[?]', n)
	local size  = self.size
	local start = pos(self, self.read_idx)
	local first = math.min(n, size - start)

	if first > 0 then
		ffi.copy(tmp, self.buf + start, first)
	end

	local rest = n - first
	if rest > 0 then
		ffi.copy(tmp + first, self.buf, rest)
	end

	self.read_idx = self.read_idx + ffi.cast('uint32_t', n)
	return tmp
end

local function copy_in(self, src, n)
	local size  = self.size
	local start = pos(self, self.write_idx)
	local first = math.min(n, size - start)

	if first > 0 then
		ffi.copy(self.buf + start, src, first)
	end

	local rest = n - first
	if rest > 0 then
		ffi.copy(self.buf, src + first, rest)
	end

	self.write_idx = self.write_idx + ffi.cast('uint32_t', n)
end

-- Parity with Lua RingBuf: write(src, count)
function ring_mt:write(src, count)
	assert(type(src) == 'string', 'RingBuf:write expects string')
	local n = count or #src
	assert(type(n) == 'number' and n >= 0, 'RingBuf:write expects non-negative count')
	assert(n <= #src, 'RingBuf:write count > #src')
	assert(n <= self:write_avail(), 'RingBuf: write xrun')
	if n == 0 then return end
	local tmp = ffi.new('uint8_t[?]', n)
	ffi.copy(tmp, src, n)
	copy_in(self, tmp, n)
end

-- Parity with Lua RingBuf: read(_, count)
function ring_mt:read(_, count)
	assert(type(count) == 'number' and count >= 0, 'RingBuf:read expects non-negative count')
	assert(count <= self:read_avail(), 'RingBuf: read xrun')
	if count == 0 then
		return ''
	end
	local tmp = copy_out(self, count)
	return ffi.string(tmp, count)
end

function ring_mt:put(str)
	assert(type(str) == 'string', 'RingBuf:put expects a string')
	local n = #str
	if n == 0 then return end
	assert(n <= self:write_avail(), 'RingBuf: write would exceed capacity')
	-- Reuse write() for semantics.
	return self:write(str, n)
end

-- Opaque mark of the current write position (for tail rollback).
-- Intended for "publish then possibly roll back" patterns in higher layers.
function ring_mt:mark_write()
	return self.write_idx
end

-- Rewind the write position to a previously obtained mark.
-- Caller must ensure no consumer progress happened since the mark.
function ring_mt:rewind_write(mark)
	self.write_idx = mark
end

function ring_mt:take(n)
	assert(type(n) == 'number' and n >= 0, 'RingBuf:take expects non-negative count')
	local avail = self:read_avail()
	if avail == 0 or n == 0 then
		return ''
	end
	if n > avail then
		n = avail
	end
	local tmp = copy_out(self, n)
	return ffi.string(tmp, n)
end

function ring_mt:tostring()
	local n = self:read_avail()
	if n == 0 then
		return ''
	end
	local old = self.read_idx
	local tmp = copy_out(self, n)
	self.read_idx = old
	return ffi.string(tmp, n)
end

function ring_mt:find(pattern)
	assert(type(pattern) == 'string' and #pattern > 0,
		'RingBuf:find expects non-empty string')
	local s = self:tostring()
	local i = s:find(pattern, 1, true)
	return i and (i - 1) or nil
end

local function RingBuf_new(size)
	local self = ring_ct(size)
	return ring_mt.init(self, size)
end

function ring_mt:capacity()
	return self.size
end

function ring_mt:advance_read(n)
	assert(type(n) == 'number' and n >= 0, 'RingBuf:advance_read expects non-negative count')
	local avail = self:read_avail()
	assert(n <= avail, 'RingBuf:advance_read out of range')
	if n == 0 then return end
	self.read_idx = self.read_idx + ffi.cast('uint32_t', n)
end

function ring_mt:peek(n)
	assert(type(n) == 'number' and n >= 0, 'RingBuf:peek expects non-negative count')
	local avail = self:read_avail()
	if avail == 0 or n == 0 then
		return ''
	end
	if n > avail then
		n = avail
	end

	-- Like tostring() but only for n bytes, and without mutating read_idx.
	local tmp   = ffi.new('uint8_t[?]', n)
	local size  = self.size
	local start = pos(self, self.read_idx)
	local first = math.min(n, size - start)

	if first > 0 then
		ffi.copy(tmp, self.buf + start, first)
	end

	local rest = n - first
	if rest > 0 then
		ffi.copy(tmp + first, self.buf, rest)
	end

	return ffi.string(tmp, n)
end

----------------------------------------------------------------------
-- LinearBuf (feature parity with Lua LinearBuf)
--   Methods required by Stream:
--     append, read_avail, peek, take, advance_read, find, tostring, reset
----------------------------------------------------------------------

local function LinearBuf_new(cap)
	cap = cap or 4096
	assert(type(cap) == 'number' and cap > 0, 'LinearBuf.new: positive initial capacity required')
	local buf = ffi.new('uint8_t[?]', cap)
	return setmetatable({ buf = buf, len = 0, cap = cap, off = 0 }, lin_mt)
end

function lin_mt:reset()
	self.len = 0
	self.off = 0
end

function lin_mt:read_avail()
	return self.len
end

local function lin_compact(self)
	-- Move unread bytes down to the start of the buffer.
	if self.off == 0 or self.len == 0 then
		self.off = 0
		return
	end
	ffi.copy(self.buf, self.buf + self.off, self.len)
	self.off = 0
end

function lin_mt:ensure(extra)
	assert(type(extra) == 'number' and extra >= 0, 'LinearBuf:ensure expects non-negative extra')
	local needed_tail = self.off + self.len + extra

	-- If we only run out of tail space but total capacity would suffice, compact.
	if needed_tail > self.cap and (self.len + extra) <= self.cap then
		lin_compact(self)
		needed_tail = self.len + extra
	end

	if needed_tail <= self.cap then
		return
	end

	local new_cap = self.cap > 0 and self.cap or 1
	while new_cap < (self.len + extra) do
		new_cap = new_cap * 2
	end

	local new_buf = ffi.new('uint8_t[?]', new_cap)
	if self.len > 0 then
		ffi.copy(new_buf, self.buf + self.off, self.len)
	end

	self.buf = new_buf
	self.cap = new_cap
	self.off = 0
end

function lin_mt:append(str)
	assert(type(str) == 'string', 'LinearBuf:append expects a string')
	local n = #str
	if n == 0 then return end

	self:ensure(n)
	ffi.copy(self.buf + (self.off + self.len), str, n)
	self.len = self.len + n
end

function lin_mt:tostring()
	if self.len == 0 then
		return ''
	end
	return ffi.string(self.buf + self.off, self.len)
end

function lin_mt:advance_read(n)
	assert(type(n) == 'number' and n >= 0 and n <= self.len, 'LinearBuf:advance_read out of range')
	if n == 0 then return end

	self.off = self.off + n
	self.len = self.len - n

	-- Compact opportunistically to keep offsets bounded.
	-- Mirrors the spirit of the Lua version’s compaction heuristics.
	if self.len == 0 then
		self.off = 0
	elseif self.off >= 4096 and self.off >= (self.cap / 2) then
		lin_compact(self)
	end
end

function lin_mt:peek(n)
	assert(type(n) == 'number' and n >= 0, 'LinearBuf:peek expects non-negative count')
	if n == 0 or self.len == 0 then return '' end
	if n > self.len then n = self.len end
	return ffi.string(self.buf + self.off, n)
end

function lin_mt:take(n)
	assert(type(n) == 'number' and n >= 0, 'LinearBuf:take expects non-negative count')
	if n == 0 or self.len == 0 then return '' end
	if n > self.len then n = self.len end
	local s = ffi.string(self.buf + self.off, n)
	self:advance_read(n)
	return s
end

-- Return 0-based offset of first occurrence of pattern in unread data, or nil.
function lin_mt:find(pattern)
	assert(type(pattern) == 'string' and #pattern > 0, 'LinearBuf:find expects non-empty string')
	if self.len == 0 then return nil end

	local plen = #pattern
	if plen > self.len then return nil end

	-- Precompute pattern bytes once.
	local pat = {}
	for i = 1, plen do
		pat[i] = string.byte(pattern, i)
	end

	local base = self.off
	local last = self.len - plen

	-- self.buf is uint8_t[]; indexing is 0-based.
	for i = 0, last do
		local ok = true
		for j = 1, plen do
			if self.buf[base + i + (j - 1)] ~= pat[j] then
				ok = false
				break
			end
		end
		if ok then
			return i
		end
	end

	return nil
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

return {
	RingBuf      = { new = RingBuf_new },
	LinearBuf    = { new = LinearBuf_new },
	has_ffi      = true,
	is_supported = function () return true end,
}

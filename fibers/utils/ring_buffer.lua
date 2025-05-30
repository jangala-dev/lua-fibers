-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

-- Ring buffer for bytes

local is_LuaJIT = rawget(_G, "jit") and true or false

local bit = rawget(_G, "bit") or require 'bit32'
local ffi = is_LuaJIT and require 'ffi' or require 'cffi'

local band = bit.band

ffi.cdef [[
    typedef struct {
        uint32_t read_idx, write_idx;
        uint32_t size;
        uint32_t _pad;               // force 8-byte alignment
        uint8_t buf[?];
    } buffer_t;
]]

local function to_uint32(n)
    return band(n, 0xffffffff)
end

local buffer = {}
buffer.__index = buffer

function buffer:init(size)
    assert(type(size) == "number" and size > 0, "size must be positive integer")
    assert(band(size, size - 1) == 0, "size must be power of two")
    self.size = size
    self:reset()
    return self
end

function buffer:reset()
    self.write_idx, self.read_idx = 0, 0
end

function buffer:is_empty()
    return self.write_idx == self.read_idx
end

function buffer:read_avail()
    return to_uint32(self.write_idx - self.read_idx)
end

function buffer:is_full()
    return self:read_avail() == self.size
end

function buffer:write_avail()
    return self.size - self:read_avail()
end

function buffer:write_pos()
    return band(self.write_idx, self.size - 1)
end

function buffer:rewrite_pos(offset)
    return band(self.read_idx + offset, self.size - 1)
end

function buffer:read_pos()
    return band(self.read_idx, self.size - 1)
end

function buffer:advance_write(count)
    assert(type(count) == "number" and count >= 0, "advance_write requires non-negative count")
    assert(count <= self:write_avail(), "advance_write out of range")
    self.write_idx = to_uint32(self.write_idx + count)
end

function buffer:advance_read(count)
    assert(type(count) == "number" and count >= 0, "advance_read requires non-negative count")
    assert(count <= self:read_avail(), "advance_read out of range")
    self.read_idx = to_uint32(self.read_idx + count)
end

function buffer:unadvance_read(count)
    assert(count >= 0 and to_uint32(count) <= self.read_idx, "unadvance_read out of range")
    self.read_idx = to_uint32(self.read_idx - count)
end
function buffer:write(bytes, count)
    assert(count and count >= 0, "invalid write count")
    assert(count <= self:write_avail(), 'write xrun')
    local pos = self:write_pos()
    local count1 = math.min(self.size - pos, count)
    if count1 > 0 then
        ffi.copy(self.buf + pos, bytes, count1)
    end
    if count > count1 then
        ffi.copy(self.buf, bytes + count1, count - count1)
    end
    self:advance_write(count)
end

function buffer:rewrite(offset, bytes, count)
    assert(type(offset) == "number" and offset >= 0, "invalid offset")
    assert(count and count >= 0, "invalid count")
    assert(offset + count <= self:read_avail(), 'rewrite xrun')
    local pos = self:rewrite_pos(offset)
    local count1 = math.min(self.size - pos, count)
    if count1 > 0 then
        ffi.copy(self.buf + pos, bytes, count1)
    end
    if count > count1 then
        ffi.copy(self.buf, bytes + count1, count - count1)
    end
end

function buffer:read(bytes, count)
    assert(count and count >= 0, "invalid read count")
    assert(count <= self:read_avail(), 'read xrun')
    local pos = self:read_pos()
    local count1 = math.min(self.size - pos, count)
    if count1 > 0 then
        ffi.copy(bytes, self.buf + pos, count1)
    end
    if count > count1 then
        ffi.copy(bytes + count1, self.buf, count - count1)
    end
    self:advance_read(count)
end

function buffer:drop(count)
    assert(count and count >= 0, "invalid drop count")
    assert(count <= self:read_avail(), 'drop xrun')
    self:advance_read(count)
end

function buffer:peek()
    local pos = self:read_pos()
    return self.buf + pos, math.min(self:read_avail(), self.size - pos)
end

function buffer:tail()
    local pos = self:write_pos()
    return self.buf + pos, math.min(self:write_avail(), self.size - pos)
end

function buffer:tostring()
    local original_read_idx = self.read_idx
    local size = self:read_avail()
    if size == 0 then return "" end
    local data = ffi.new("uint8_t[?]", size)
    self:read(data, size)
    self.read_idx = original_read_idx
    return ffi.string(data, size)
end

function buffer:find(pattern)
    assert(type(pattern) == "string" and #pattern > 0, "find requires non-empty string")
    local buf_string = self:tostring()
    local found_at = string.find(buf_string, pattern)
    return found_at and (found_at - 1) or nil
end

function buffer:find_string(s)
    assert(type(s) == "string" and #s > 0, "find_string requires non-empty string")
    local len = #s
    local end_idx = self:read_avail()
    if end_idx < len then return nil end
    for i = 0, end_idx - len do
        local found = true
        for j = 1, len do
            local buf_idx = self:rewrite_pos(i + j - 1)
            if ffi.string(self.buf + buf_idx, 1) ~= s:sub(j, j) then
                found = false
                break
            end
        end
        if found then return i end
    end
    return nil
end

local buffer_t = ffi.metatype("buffer_t", buffer)

local function new(size)
    assert(type(size) == "number" and size > 0, "new() requires a positive size")
    return buffer_t(size):init(size)
end

return {
    new = new
}

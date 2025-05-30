-- Use of the provided source code for ring buffer

local ring_buffer = require 'fibers.utils.ring_buffer' -- assuming the above code is saved as ring_buffer.lua

local is_LuaJIT = rawget(_G, "jit") and true or false
local ffi = is_LuaJIT and require 'ffi' or require 'cffi'

local str_buffer = {}
str_buffer.__index = str_buffer

function str_buffer.new(size)
    local obj = {}
    obj.buf = ring_buffer.new(size or 64) -- Default size is 64
    return setmetatable(obj, str_buffer)
end

function str_buffer:len()
    return self.buf:read_avail()
end

function str_buffer:cap()
    return self.buf.size
end

function str_buffer:reset()
    self.buf:reset()
end

function str_buffer:string()
    local data, length = self.buf:peek()
    return ffi.string(data, length)
end

function str_buffer:write(data)
    assert(type(data) == "string", "write requires a string")
    if #data == 0 then return end
    local len = #data
    local avail = self.buf:write_avail()
    if avail < len then
        self:grow(len - avail)
    end
    local cdata = ffi.new("uint8_t[?]", len)
    ffi.copy(cdata, data, len)
    self.buf:write(cdata, len)
end

function str_buffer:write_to(w)
    -- Assuming 'w' is a function or a file-like object that can accept a string.
    local data = self:string()
    w(data)
    self.buf:drop(#data)
end

function str_buffer:read(n)
    local count = n or self.buf:read_avail()
    assert(count >= 0, "read: negative count")
    assert(count <= self.buf:read_avail(), "read: buffer underflow")
    local buffer = ffi.new('uint8_t[?]', count)
    self.buf:read(buffer, count)
    return ffi.string(buffer, count)
end

function str_buffer:next(n)
    assert(n >= 0, "next: negative count")
    assert(n <= self.buf:read_avail(), "next: buffer underflow")
    local buffer = ffi.new('uint8_t[?]', n)
    self.buf:read(buffer, n)
    return ffi.string(buffer, n)
end

function str_buffer:unread_char()
    return self.buf:unadvance_read(1)
end

function str_buffer:grow(n)
    assert(n >= 0, "grow: negative count")

    local new_size = self:cap() + n
    local power = 1
    while power < new_size do power = power * 2 end
    new_size = power

    local new_buf = ring_buffer.new(new_size)

    local read_pos = self.buf:read_pos()
    local read_avail = self.buf:read_avail()
    local first_chunk_len = math.min(read_avail, self.buf.size - read_pos)
    local second_chunk_len = read_avail - first_chunk_len

    assert(new_buf:write_avail() >= read_avail, "new buffer too small")

    new_buf:write(self.buf.buf + read_pos, first_chunk_len)
    if second_chunk_len > 0 then
        new_buf:write(self.buf.buf, second_chunk_len)
    end

    self.buf = new_buf
end

return {
    new = str_buffer.new
}

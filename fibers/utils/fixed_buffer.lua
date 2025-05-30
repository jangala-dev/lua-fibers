local is_LuaJIT = rawget(_G, "jit") and true or false
local ffi = is_LuaJIT and require 'ffi' or require 'cffi'

local ljbuf = require("string.buffer")

local ring_buffer = {}

function ring_buffer:reset()
    self.buf:reset()
end

function ring_buffer:read_avail()
    return #self.buf
end

function ring_buffer:write_avail()
    return self.size - #self.buf
end

function ring_buffer:is_empty()
    return #self.buf == 0
end

function ring_buffer:is_full()
    return #self.buf >= self.size
end

function ring_buffer:advance_read(count)
    assert(count >= 0 and count <= #self.buf, "advance_read out of range")
    self.buf:skip(count)
end

function ring_buffer:write(bytes, count)
    assert(count >= 0, "invalid write count")
    assert(count <= self:write_avail(), "write xrun")
    self.buf:putcdata(bytes, count)
end

function ring_buffer:read(bytes, count)
    assert(count >= 0 and count <= #self.buf, "read xrun")
    local data = self.buf:get(count)
    ffi.copy(bytes, data, #data)
end

function ring_buffer:peek()
    local ptr, len = self.buf:ref()
    return ptr, math.min(len, self.size)
end

function ring_buffer:tostring()
    return self.buf:tostring()
end

function ring_buffer:find(pattern)
    assert(type(pattern) == "string" and #pattern > 0, "pattern must be non-empty string")
    local str = self.buf:tostring()
    local i = string.find(str, pattern)
    return i and (i - 1) or nil
end

function ring_buffer:reserve(size)
    return self.buf:reserve(size)
end

function ring_buffer:commit(n)
    return self.buf:commit(n)
end

local function new(size)
    assert(type(size) == "number" and size > 0, "new() requires positive size")
    local self = {
        buf = ljbuf.new(),
        size = size
    }

    return setmetatable(self, { __index = ring_buffer })
end

return {
    new = new
}

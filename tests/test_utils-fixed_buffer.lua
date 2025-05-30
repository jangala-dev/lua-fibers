--- Tests the fixed_buffer implementation.
print('testing: fibers.utils.fixed_buffer')

package.path = "../?.lua;" .. package.path

local buffer = require 'fibers.utils.ring_buffer' -- This now refers to your new fixed_buffer
local sc = require 'fibers.utils.syscall'
local ffi = sc.is_LuaJIT and require 'ffi' or require 'cffi'

local equal = require 'fibers.utils.helper'.equal

local function assert_throws(f, ...)
    local success, ret = pcall(f, ...)
    assert(not success, "expected failure but got " .. tostring(ret))
end

local function assert_avail(b, readable, writable)
    assert(b:read_avail() == readable)
    assert(b:write_avail() == writable)
end

local function write_str(b, str)
    local scratch = ffi.new('uint8_t[?]', #str)
    ffi.copy(scratch, str, #str)
    b:write(scratch, #str)
end

local function read_str(b, count)
    local scratch = ffi.new('uint8_t[?]', count)
    b:read(scratch, count)
    return ffi.string(scratch, count)
end

local function test_basic()
    assert_throws(buffer.new, 0)

    local b = buffer.new(16)
    assert_avail(b, 0, 16)

    for _ = 1, 10 do
        local s = "hello"
        write_str(b, s)
        assert(read_str(b, #s) == s)
        assert_avail(b, 0, 16)
    end

    -- Peek and skip
    write_str(b, "abc")
    local ptr, len = b:peek()
    assert(len >= 3)
    assert(ffi.string(ptr, 3) == "abc")
    b:advance_read(3)
    assert(b:is_empty())
end

local function test_find()
    local b = buffer.new(64)
    write_str(b, "abcdef\n12345")
    assert(b:find("\n123") == 6)
    b:advance_read(7)
    assert(read_str(b, 5) == "12345")
end

local function test_large_buffer()
    local size = 2 ^ 20 -- 1 MB
    local data = ffi.new('uint8_t[?]', size)
    for i = 0, size - 1 do
        data[i] = i % 256
    end

    local b = buffer.new(size)

    local start = sc.monotime()
    b:write(data, size)
    local write_time = sc.monotime() - start
    print(string.format("Wrote %d MB in %d microseconds", size / 2^20, write_time * 1e6))

    local read_buf = ffi.new('uint8_t[?]', size)
    start = sc.monotime()
    b:read(read_buf, size)
    local read_time = sc.monotime() - start
    print(string.format("Read %d MB in %d microseconds", size / 2^20, read_time * 1e6))

    start = sc.monotime()
    assert(equal(data, read_buf), "Data mismatch")
    local verify_time = sc.monotime() - start
    print(string.format("Verified in %d microseconds", verify_time * 1e6))
end

test_basic()
test_find()
test_large_buffer()

print("test: ok")

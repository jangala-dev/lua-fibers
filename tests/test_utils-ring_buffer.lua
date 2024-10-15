--- Tests the Buffer implementation.
print('testing: fibers.utils.ring_buffer')

-- look one level up
package.path = "../?.lua;" .. package.path

local buffer = require 'fibers.utils.ring_buffer'
local sc = require 'fibers.utils.syscall'
local ffi = sc.is_LuaJIT and require 'ffi' or require 'cffi'

local equal = require 'fibers.utils.helper'.equal

local function to_uint32(n)
    return n % 2 ^ 32
end

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

local function original_test()
    assert_throws(buffer.new, 10)
    local b = buffer.new(16)
    assert_avail(b, 0, 16)
    for _ = 1, 10 do
        local s = '0123456789'
        write_str(b, s)
        assert_avail(b, #s, 16 - #s)
        assert(read_str(b, #s) == s)
        assert_avail(b, 0, 16)
    end

    local _, avail = b:peek()
    assert(avail == 0)
    write_str(b, "foo")
    _, avail = b:peek()
    assert(avail > 0)

    -- Test wrap of indices.
    local s = "overflow"
    b.read_idx = to_uint32(3 - #s)
    b.write_idx = b.read_idx
    assert_avail(b, 0, 16)
    write_str(b, s)
    assert_avail(b, #s, 16 - #s)
    assert(read_str(b, #s) == s)
    assert_avail(b, 0, 16)

    -- Benchmark

    -- The size of the buffer and the data to write to it
    local size = 2 ^ 20 -- 1 MB
    local data = ffi.new('uint8_t[?]', size)

    -- Fill the data with some values
    for i = 0, size - 1 do
        data[i] = i % 256
    end

    -- Create the buffer
    local buf = buffer.new(size)

    -- Benchmark the write operation
    local start_time = sc.monotime()
    buf:write(data, size)
    local write_time = sc.monotime() - start_time
    print(string.format("Writing %d MB to the buffer took %d microseconds", size / 2 ^ 20, write_time * 1e6))

    -- Benchmark the read operation
    local read_data = ffi.new('uint8_t[?]', size)
    start_time = sc.monotime()
    buf:read(read_data, size)
    local read_time = sc.monotime() - start_time
    print(string.format("Reading %d MB to the buffer took %d microseconds", size / 2 ^ 20, read_time * 1e6))

    -- Verify that the data read is the same as the data written
    start_time = sc.monotime()
    assert(equal(data, read_data), "Data mismatch")
    local ver_time = sc.monotime() - start_time
    print(string.format("Data verification successful in %f seconds", ver_time))
end

local function test_find_string()
    local buf_exp = 24
    local b = buffer.new(2 ^ buf_exp)

    local rep = "ab"
    local spec_1 = "\r\n"
    local spec_2 = "yz"

    -- Simulate writing data to wrap around the buffer
    write_str(b, string.rep(rep, (2^(buf_exp-1)) - 1))
    write_str(b, spec_1)

    assert(b:write_avail()==0)

    assert(read_str(b, 2)==rep) -- will read "ab"

    write_str(b, spec_2)

    -- Now the buffer has wrapped around data
    -- Content of the buffer visually:
    -- Indices: 0       1       2       3       4      ...   2^24-2    2^24-1
    -- Data:   'y'     'z'     'a'     'b'     'a'    ...    '\r'      '\n'

    -- Attempt to find a string that spans across the end and start of the buffer
    local search_str = spec_1..spec_2
    local pos = assert(b:find(search_str))

    b:advance_read(pos)

    assert(read_str(b, #search_str)==search_str)
end


original_test()
test_find_string()


print('test: ok')

--- Tests the Stream implementation.
print('testing: fibers.stream')

-- look one level up
package.path = "../?.lua;" .. package.path

local fiber = require 'fibers.fiber'
local stream = require 'fibers.stream'
local sc = require 'fibers.utils.syscall'
local ffi = sc.is_LuaJIT and require 'ffi' or require 'cffi'

local function test()
    local rd_io, wr_io = {}, {}
    local rd, wr = stream.open(rd_io, true, false), stream.open(wr_io, false, true)

    function rd_io:close() end

    function rd_io:read() return 0 end

    function wr_io:write(buf, count)
        rd.rx:write(buf, count)
        return count
    end

    function wr_io:close() end

    local message = "hello, world\n"
    wr:setvbuf('line')
    wr:write(message)
    local message2 = rd:read_some_chars()
    assert(message == message2)
    assert(rd:read_some_chars() == nil)

    rd:close(); wr:close()
end

-- tests for a memory leak by asking to read more bytes than the provided array can hold
local function test_memory_leak()
    local small_buf_size = 4
    local small_buf_count = 32
    local rd_io, wr_io = {}, {}
    local rd, wr = stream.open(rd_io, true, false), stream.open(wr_io, false, true)

    function rd_io:close() end

    function rd_io:read() return 0 end

    function wr_io:write(buf, count)
        rd.rx:write(buf, count)
        return count
    end

    function wr_io:close() end

    wr:setvbuf('line')
    wr:write("0123456789012345678901234567890\n")

    local buf = ffi.new('uint8_t[?]', small_buf_size)
    local retbuf, read_num, err = rd:read_bytes(buf, small_buf_count)

    assert(not err)
    assert(read_num == small_buf_count)
    assert(rd:read_some_chars() == nil)
    assert(ffi.sizeof(retbuf) >= small_buf_count)

    rd:close()
    wr:close()
end
fiber.spawn(function ()
    test()
    test_memory_leak()
    fiber.stop()
end)

fiber.main()

print('selftest: ok')

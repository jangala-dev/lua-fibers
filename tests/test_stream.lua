--- Tests the Stream implementation.
print('testing: fibers.stream')

-- look one level up
package.path = "../src/?.lua;" .. package.path

local fibers = require 'fibers'
local stream = require 'fibers.stream'

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

local function main()
    test()
end

fibers.run(main)

print('selftest: ok')

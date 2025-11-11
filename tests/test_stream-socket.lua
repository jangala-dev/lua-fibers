--- Tests the Stream Socket implementation.
print('testing: fibers.stream.socket')

-- look one level up
package.path = "../src/?.lua;" .. package.path

local fibers = require 'fibers'
local socket = require 'fibers.stream.socket'
local sc = require 'fibers.utils.syscall'

local function test()
    local sockname = '/tmp/test-socket'
    sc.unlink(sockname)

    local server = socket.listen_unix(sockname)
    local client = socket.connect_unix(sockname)
    local peer = server:accept()

    local messages = { "hello\n", "world\n" }
    for _, msg in ipairs(messages) do
        client:write(msg)
        client:flush_output()
        local res = peer:read_some_chars()
        assert(msg == res)
    end
    client:close()
    assert(peer:read_some_chars() == nil)
    peer:close()

    server:close()

    sc.unlink(sockname)
end


local function main()
    test()
end

fibers.run(main)

print('test: ok')

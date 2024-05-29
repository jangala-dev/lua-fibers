--- Tests the Stream File implementation.
print('testing: fibers.stream.file')

-- look one level up
package.path = "../?.lua;" .. package.path

local fiber = require 'fibers.fiber'
local waitgroup = require "fibers.waitgroup"
local op = require 'fibers.op'
local sleep = require 'fibers.sleep'
local channel = require 'fibers.channel'
local file = require 'fibers.stream.file'
local sc = require 'fibers.utils.syscall'

local ffi = sc.is_LuaJIT and require 'ffi' or require 'cffi'

local function test()
    local rd, wr = file.pipe()
    local message = "hello, world\n"

    wr:setvbuf('line')
    wr:write(message)
    local message2 = rd:read_some_chars()
    assert(message == message2)
    wr:close()
    assert(rd:read_some_chars() == nil)
    rd:close()

    local subprocess = file.popen('echo "hello"; echo "world"', 'r')
    local lines = {}
    while true do
        local line, err = subprocess:read_line()
        assert(not err)
        if line then table.insert(lines, line) else break end
    end
    local res, exit_type, code = subprocess:close()
    assert(res)
    assert(exit_type == "exit")
    assert(code == 0)
    assert(#lines == 2)
    assert(lines[1] == 'hello')
    assert(lines[2] == 'world')
end

local function test_long_read_first()
    local rd, wr = file.pipe()
    local message = string.rep("a", 2^24)

    fiber.spawn(function ()
        wr:write_chars(message)
        wr:close()
    end)

    local buf, count = rd:read_all_bytes()
    assert(count==#message)
    assert(message==ffi.string(buf, count))

    rd:close()
end

local function test_read_op()
    local msg1 = "hello\n"
    local msg2 = "world\n"
    local rd, wr = file.pipe()
    wr:setvbuf('line') -- new lines will automatically be flushed

    local wg = waitgroup.new()
    wg:add(1)

    fiber.spawn(function ()
        local count, err = wr:write_chars(msg1)
        assert(count==#msg1 and not err)
        sleep.sleep(0.05)
        count, err = wr:write_chars(msg2)
        assert(count==#msg2 and not err)
        wr:close()
        wg:done()
    end)

    local chars, err = op.choice(
        rd:read_all_chars_op(),
        sleep.sleep_op(0.01):wrap(function () return nil, 'timeout' end)
    ):perform()

    assert(not chars and err == 'timeout')

    local did_read, read_string = rd:partial_read()
    assert(did_read == #msg1 and read_string == msg1)

    rd:reset_partial_read()
    assert(not rd._part_read)

    chars, err = rd:read_all_chars()
    assert(not err and chars==msg2)

    assert(not rd._part_read)

    rd:close()
    wg:wait()
end

local function test_write_op()
    local msg = string.rep("a", 2^16) -- needed because Linux has a 64KB buffer for a pipe
    local msg2 = "hello world\n"
    local rd, wr = file.pipe()
    wr:setvbuf('no') -- no output buffering

    local wg = waitgroup.new()
    wg:add(1)

    fiber.spawn(function ()
        sleep.sleep(0.1)
        local chars, err = rd:read_chars(2^16)
        assert(chars==string.rep("a", 2^16) and not err)
        chars, err = rd:read_all_chars()
        assert(chars==msg2 and not err)
        rd:close()
        wg:done()
    end)

    local written, err = op.choice(
        wr:write_chars_op(msg..msg2),
        sleep.sleep_op(0.01):wrap(function () return nil, 'timeout' end)
    ):perform()

    assert(not written and err=='timeout')

    local did_write = wr:partial_write()
    assert(did_write == 2^16)

    wr:reset_partial_write()
    assert(not wr._part_write)

    did_write, err = wr:write_chars(msg2)
    assert(not err and did_write==#msg2)

    assert(not wr._part_write)

    wr:close()
    wg:wait()
end

local function test_long_write_first()
    local rd, wr = file.pipe()
    local chan = channel.new()
    local message = string.rep("a", 2^24)

    local buf, count

    fiber.spawn(function ()
        buf, count = rd:read_all_bytes()
        rd:close()
        chan:put(1)
    end)

    wr:write_chars(message)
    wr:close()

    chan:get()

    assert(count==#message)
    assert(message==ffi.string(buf, count))
end

local function test_tiny_writes()
    local rd, wr = file.pipe()
    local message = string.rep("a", 2^16)

    fiber.spawn(function ()
        for c in message:gmatch"." do
            wr:write(c)
        end
        wr:close()
    end)

    local buf, count = rd:read_all_bytes()
    assert(count==#message)
    assert(message==ffi.string(buf, count))

    rd:close()
end

local function test_single()
    local rd, wr = file.pipe()
    local message = "aa"

    fiber.spawn(function ()
        wr:write_chars(message)
        wr:close()
    end)

    assert(rd:read_byte() == 97)
    assert(rd:read_char() == "a")
    assert(rd:read_byte() == nil)

    rd:close()
end

local function test_lua()
    local msg1 = "It\n"
    local msg2 = "was\n"
    local msg3 = "the\n"
    local msg4 = "best\n"
    local msg5 = "of\n"
    local msg6 = "times"

    local rd, wr = file.pipe()
    wr:setvbuf('no')

    assert(wr:write(msg1, msg2, msg3, msg4, msg5, msg6))
    wr:close()

    assert(rd:read("*l")==string.sub(msg1,1,#msg1-1))
    assert(rd:read("*L")==msg2)
    assert(rd:read(#msg3)==msg3)
    assert(rd:read(#msg4)==msg4)
    assert(rd:read("*a")==msg5..msg6)
    assert(rd:read("*a")=="") -- on EOF read("*a") returns the empty string
    assert(rd:read("*l")==nil) -- on EOF read("*l") returns nil

    rd:close()
end

fiber.spawn(function ()
    test()
    test_read_op()
    test_write_op()
    test_long_read_first()
    test_long_write_first()
    test_tiny_writes()
    test_single()
    test_lua()
    fiber.stop()
end)
fiber.main()

print('test: ok')

-- test_fibers_exec.lua
package.path = "../../?.lua;../?.lua;" .. package.path

local fiber = require 'fibers.fiber'
local channel = require "fibers.channel"
local exec = require 'fibers.exec'
local pollio = require 'fibers.pollio'
local sleep = require "fibers.sleep"
local sc = require 'fibers.utils.syscall'


pollio.install_poll_io_handler()

-- Test 1: Test basic command execution
local function test_basic_execution()
    local output, err = exec.command('echo', 'Hello, World!'):combined_output()
    -- remember that echo will append a new line character!
    assert(output == "Hello, World!\n", "Expected 'Hello, World!' but got: " .. output)
    assert(err == nil, "Expected no error but got: ", err)
    print("Test 1: Basic command execution passed!")
end

-- Test 2: Test command error handling
local function test_command_error()
    local output, err = exec.command('nonexistent_command'):combined_output()
    assert(output == "", "Expected no output but got: " .. output)
    assert(err ~= nil, "Expected an error!")
    print("Test 2: Command error handling passed!")
end

-- Test 3: Test command with arguments
local function test_command_with_args()
    local output, err = exec.command('echo', 'arg1', 'arg2'):combined_output()
    assert(output == "arg1 arg2\n", "Expected 'arg1 arg2' but got: " .. output)
    assert(err == nil, "Expected no error but got: ", err)
    print("Test 3: Command with arguments passed!")
end

-- Test 4: Test command IO redirection
local function test_io_redirection()
    local msgs = {"Hello", "World"}
    local cmd = exec.command('cat')
    local stdin_pipe = assert(cmd:stdin_pipe())
    local stdout_pipe = assert(cmd:stdout_pipe())
    local signal_chan = channel.new()
    fiber.spawn(function ()
        for _, v in ipairs(msgs) do
            stdin_pipe:write(v)
            signal_chan:get()
        end
        stdin_pipe:close()
    end)
    local err = cmd:start()
    assert(err == nil, "Expected no error but got:", err)
    for _, v in ipairs(msgs) do
        assert(stdout_pipe:read_some_chars() == v)
        signal_chan:put(1)
    end
    assert(stdout_pipe:read_some_chars() == nil)
    local err = cmd:wait()
    assert(err == nil, "Expected no error but got:", err)
    assert(cmd.process_state.ssi_status == 0)
    print("Test 4: IO redirection passed!")
end

-- Test 5: Test command kill 
local function test_kill()
    local cmd = exec.command('/bin/sh', '-c', 'sleep 5')
    local starttime = sc.monotime()
    local err = cmd:start()
    assert(err == nil, "Expected no error but got:", err)
    sleep.sleep(0.5)
    cmd:kill()
    assert(cmd:wait() == sc.SIGTERM)
    local duration = sc.monotime() - starttime
    assert(duration<1)
    print("Test 5: Kill passed!")
end

-- Main test function
local function main()
    print("testing: fibers.exec")
    test_basic_execution()
    test_command_error()
    test_command_with_args()
    test_io_redirection()
    test_kill()
    print("test: ok")
    fiber.stop()
end

fiber.spawn(main)
fiber.main()

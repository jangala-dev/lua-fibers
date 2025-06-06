-- test_fibers_exec.lua
package.path = "../../?.lua;../?.lua;" .. package.path

local fiber = require 'fibers.fiber'
local sleep = require 'fibers.sleep'
local channel = require "fibers.channel"
local exec = require 'fibers.exec'
local pollio = require 'fibers.pollio'
local waitgroup = require "fibers.waitgroup"
local context = require "fibers.context"
local sc = require 'fibers.utils.syscall'

pollio.install_poll_io_handler()

local function count_dir_items(path)
    local count
    local p = io.popen('ls -1 "' .. path .. '" | wc -l')
    if p then
        local output = p:read("*all")
        count = tonumber(output)
        p:close()
    end
    return count
end

local function count_zombies()
    local count
    local p = io.popen('ps | grep -c " Z "')
    if p then
        local output = p:read("*all")
        count = tonumber(output)
        p:close()
    end
    return count
end

-- Test 1: Test basic command execution
local function test_basic_execution()
    local output, err = exec.command('echo', 'Hello, World!'):combined_output()
    if err then error(err) end
    -- remember that echo will append a new line character!
    assert(output == "Hello, World!\n", "Expected 'Hello, World!' but got: " .. output)
    assert(err == nil, "Expected no error but got: ", err)
end

-- Test 2: Test command error handling
local function test_command_error()
    local output, err = exec.command('nonexistent_command'):combined_output()
    assert(output == nil, "Expected no output but got: ", output)
    assert(err ~= nil, "Expected an error!")
end

-- Test 3: Test command with arguments
local function test_command_with_args()
    local output, err = exec.command('echo', 'arg1', 'arg2'):combined_output()
    if err then error(err) end
    assert(output == "arg1 arg2\n", "Expected 'arg1 arg2' but got: " .. output)
    assert(err == nil, "Expected no error but got: ", err)
end

-- Test 4: Test command IO redirection
local function test_io_redirection()
    local msgs = {"Hello", "World"}
    local cmd = exec.command('cat')
    local stdin_pipe = assert(cmd:stdin_pipe())
    local stdout_pipe = assert(cmd:stdout_pipe())
    local signal_chan = channel.new()
    local err = cmd:start()
    assert(cmd:start(), "Expected error on starting command twice")
    assert(err == nil, "Expected no error but got:", err)
    fiber.spawn(function ()
        for _, v in ipairs(msgs) do
            stdin_pipe:write(v)
            signal_chan:get()
        end
        stdin_pipe:close()
    end)
    for _, v in ipairs(msgs) do
        assert(stdout_pipe:read_some_chars() == v)
        signal_chan:put(1)
    end
    assert(stdout_pipe:read_some_chars() == nil)
    stdout_pipe:close()
    err = cmd:wait()
    assert(err == nil, "Expected no error but got:", err)
    assert(cmd.process.state == 0)
end

-- Test 5: Test command kill
local function test_kill()
    local cmd = exec.command('/bin/sh', '-c', 'sleep 5')
    cmd:setpgid(true) -- ensures that children run in a separate process group
    local starttime = sc.monotime()
    local err = cmd:start()
    assert(err == nil, "Expected no error but got:", err)
    cmd:kill()
    local exit_code = cmd:wait()
    assert(exit_code == sc.SIGKILL)
    assert(sc.monotime()-starttime < 4, sc.monotime()-starttime)
end

-- Test 6: Testing context
local function test_context()
    local ctx, _ = context.with_timeout(context.background(), 0.00001)
    local cmd = exec.command_context(ctx, 'sleep', '5')
    local starttime = sc.monotime()
    local err = cmd:start()
    assert(err == nil, "Expected no error but got:", err)
    assert(cmd:wait() == sc.SIGKILL)
    assert(sc.monotime()-starttime < 4, sc.monotime()-starttime)
end

-- Test 7: Cancel context during output
local function test_cancel_during_output()
    local ctx, cancel = context.with_cancel(context.background())
    local cmd = exec.command_context(ctx, '/bin/sh', '-c', 'for i in $(seq 1 10000); do echo y; sleep 0.001; done')
        :setpgid(true)

    fiber.spawn(function()
        -- Let it run for a short moment, then cancel
        sleep.sleep(0.00001)
        cancel()
    end)

    local err = cmd:run()
    assert(err == sc.SIGKILL, "Expected error due to cancellation")
end

-- Test 8: Context already cancelled before start
local function test_cancel_before_start()
    local ctx, cancel = context.with_cancel(context.background())
    cancel()

    local cmd = exec.command_context(ctx, '/bin/true')
    local err = cmd:start()
    assert(err ~= nil, "Expected start() to fail due to cancelled context")
end

-- Main test function
local function main()
    local pid = sc.getpid()
    local base_open_fds = count_dir_items("/proc/"..pid.."/fd")
    local base_zombies = count_zombies()
    local reps = 100
    print("testing: fibers.exec")
    local tests = {
        test_basic_execution = test_basic_execution,
        test_command_error = test_command_error,
        test_command_with_args = test_command_with_args,
        test_io_redirection = test_io_redirection,
        test_kill = test_kill,
        test_context = test_context,
        test_cancel_during_output = test_cancel_during_output,
        test_cancel_before_start = test_cancel_before_start
    }
    for k, v in pairs(tests) do
        local wg = waitgroup.new()
        for _ = 1, reps do
            wg:add(1)
            fiber.spawn(function ()
                v()
                wg:done()
            end)
        end
        wg:wait()
        assert(base_open_fds == count_dir_items("/proc/"..pid.."/fd"), k.." left open fds!")
        assert(base_zombies == count_zombies(), k.." created zombies!")
        print(k..": passed!")
    end
    print("test: ok")
    fiber.stop()
end

fiber.spawn(main)
fiber.main()

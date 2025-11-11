-- test_fibers_exec.lua

-- look one level up
package.path = "../src/?.lua;" .. package.path

local fibers = require 'fibers'
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
    fibers.spawn(function ()
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

    fibers.spawn(function()
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

local function test_cleanup_on_crash(id)
    local function is_process_running(pid)
        local f = assert(io.popen('ps -p ' .. pid .. ' | wc -l'))
        local output = f:read("*all")
        f:close()
        return tonumber(output) > 1 -- More than 1 means the process is running
    end
    local temp_script_dir = "/tmp/crash_test" .. id .. ".lua"

    local script = [[
            package.path = "../src/?.lua;" .. package.path
            local fibers = require 'fibers'
            local exec = require 'fibers.exec'
            local sleep = require 'fibers.sleep'
            local pollio = require 'fibers.pollio'
            local sc = require 'fibers.utils.syscall'
            pollio.install_poll_io_handler()

            local function main()
                local cmd = exec.command('sleep', '1')
                cmd:setprdeathsig(sc.SIGKILL)
                local err = cmd:start()
                if err then
                    error(err)
                end
                io.stdout:write(tostring(cmd.process.pid) .. "\n")
                io.stdout:flush()
                sleep.sleep(0.01)
                print(obj.obj)
            end

            fibers.run(main)
    ]]

    -- Write the script to a temporary file
    local file = assert(io.open(temp_script_dir, "w"))
    file:write(script)
    file:close()

    -- Execute the script using luajit
    local cmd = exec.command('luajit', temp_script_dir)
    local stdout = assert(cmd:stdout_pipe())
    assert(cmd:start() == nil, "Expected no error on start")

    -- Wait for line output from script
    local lines
    for _ = 1, 10 do
        lines = stdout:read_line()
        if lines then
            break
        end
        sleep.sleep(0.01) -- Wait a bit for output
    end
    local exit_code = cmd:wait()
    stdout:close()
    assert(exit_code ~= 0, "Expected non-zero exit code due to crash")

    os.remove(temp_script_dir)

    -- Get the process ID of the sleep command
    local pid = lines and tonumber(lines:match("^(%d+)"))
    assert(pid, "Expected a valid process ID from output: " .. tostring(lines or 'nil'))
    local is_running = is_process_running(pid)

    -- If we have a valid pid, make sure to cleanup the sleep command explicitly
    if pid and pid > 0 and is_running then
        -- Send SIGKILL to the process
        local kill_cmd = assert(io.popen('kill -9 ' .. tostring(pid)))
        kill_cmd:close()

        -- Give a small amount of time for the kill to take effect
        sleep.sleep(0.1)

        local running = is_process_running(pid)

        assert(not running,
            "Process " .. pid .. " still exists after kill")
    end

    assert(not is_running, "Child sleep command is still running")
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
        test_cancel_before_start = test_cancel_before_start,
        test_cleanup_on_crash = test_cleanup_on_crash,
    }
    for k, v in pairs(tests) do
        local wg = waitgroup.new()
        for i = 1, reps do
            wg:add(1)
            fibers.spawn(function ()
                v(i)
                wg:done()
            end)
        end
        wg:wait()
        assert(base_open_fds == count_dir_items("/proc/"..pid.."/fd"), k.." left open fds!")
        assert(base_zombies == count_zombies(), k.." created zombies!")
        print(k..": passed!")
    end
    print("test: ok")
end

fibers.run(main)

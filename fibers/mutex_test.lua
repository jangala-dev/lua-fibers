package.path = "../../?.lua;../?.lua;" .. package.path

print("program size", collectgarbage("count")*1024)
local op = require 'fibers.op'
local fiber = require 'fibers.fiber'
local channel = require 'fibers.channel'
local sleep = require 'fibers.sleep'
local mutex = require 'fibers.mutex'
local waitgroup = require 'fibers.waitgroup'
local syscall = require 'fibers.utils.syscall'
print("program size", collectgarbage("count")*1024)

local function trylock_test(m)
    local wg = waitgroup.new()
    local successes, failures = 0,0
    local outer, inner = 400, 40
    local start = syscall.monotonic_float()
    for i=1,outer do
        wg:add(1)
        fiber.spawn(function()
            for j=1,inner do
                if m:trylock() then
                    successes = successes + 1
                    m:unlock()
                else
                    failures = failures + 1
                end
                sleep.sleep(0.01)
            end
            wg:done()
        end)
    end
    wg:wait()
    print("successes", successes, "failures", failures, "in", syscall.monotonic_float()-start)
end

local function lockunlock_test(m)
    local wg = waitgroup.new()
    local outer, inner = 1000, 10
    local start = syscall.monotonic_float()
    for i=1,outer do
        wg:add(1)
        fiber.spawn(function()
            for j=1,inner do
                sleep.sleep(0.1)
                m:lock()
                m:unlock()
            end
            wg:done()
        end)
    end
    wg:wait()
    
    print("Completed", outer*inner, "lock/unlocks in", syscall.monotonic_float()-start)
end

local function var_protector(m)
    local wg = waitgroup.new()
    local num_workers = 10
    local num_reps = 100
    local x = 0
    local function worker()
        sleep.sleep(math.random()/1000)
        m:lock()
        local temp = x
        sleep.sleep(math.random()/1000)
        x = temp + 1
        m:unlock()
    end
    local start = syscall.monotonic_float()
    for i=1,num_workers do
        wg:add(1)
        fiber.spawn(function()
            for j=1,num_reps do
                worker()
            end
            wg:done()
        end)
    end
    wg:wait()
    assert(x==num_workers*num_reps)
    print("X =", x, "by workers in", syscall.monotonic_float()-start)
end

local function yield_speed_test()
    local ywg = waitgroup.new()
    local num_routines, num_yields_each = 10,1e5
    local start = syscall.monotonic_float()
    for i=1,num_routines do
        ywg:add(1)
        fiber.spawn(function()
            for j=1,num_yields_each do
                fiber.yield()
            end
            ywg:done()
        end)
    end
    ywg:wait()
    print(num_routines*num_yields_each, "yields completed in", syscall.monotonic_float()-start)
end

local function op_choice_speed_test()
    local num_channels = 2
    local num_reps=1e5

    local wg = waitgroup.new()
    local matrix = {}

    for i=1,num_channels do
        table.insert(matrix, channel.new())
    end

    
    local function sender(mat, wg)
        local params = {}
        for i=1,num_reps do
            local ch_num = math.random(num_channels)
            -- print("sending", i, "on channel", ch_num)
            mat[ch_num]:put(i)
        end
        wg:done()
    end
    
    local function receiver(mat, wg)
        local params = {}
        for i, j in ipairs(mat) do
            params[i] = j:get_operation()
        end
        for i=1,num_reps do
            op.choice(unpack(params)):perform()
        end
        wg:done()
    end
    
    wg:add(2)
    local start = syscall.monotonic_float()
    fiber.spawn(function()
        sender(matrix, wg)
    end)
    fiber.spawn(function()
        receiver(matrix, wg) 
    end)
    wg:wait()
    print(num_channels*num_reps, "choice operations performed in", syscall.monotonic_float()-start)
end


local function main()
    local tests = {
        trylock_test,
        lockunlock_test,
        var_protector,
        yield_speed_test,
        op_choice_speed_test
    }

    local m = mutex.new()

    m:lock()
    m:unlock()
    print(assert(m:trylock()), "should return true")
    print(assert(not m:trylock()), "should also return true")
    m:unlock()
    m:lock()
    m:unlock()

    local topwait = waitgroup.new()

    for _, j in ipairs(tests) do
        topwait:add(1)
        fiber.spawn(function()
            j(m)
            topwait:done()
        end)
    end

    
    topwait:wait()
    print("all tests complete")
end

fiber.spawn(function()
    main()
    fiber.stop()
end)
fiber.main()
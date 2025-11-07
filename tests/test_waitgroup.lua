--- Tests the Waitgroup implementation.
print('testing: fibers.waitgroup')

-- look one level up
package.path = "../?.lua;" .. package.path

-- test_waitgroup.lua
local fiber = require 'fibers.fiber'
local sleep = require 'fibers.sleep'
local op = require 'fibers.op'
local waitgroup = require 'fibers.waitgroup'
local sc = require 'fibers.utils.syscall'

local function test_nowait()
    local wg = waitgroup.new()
    local task = wg:wait_op():or_else(function()
        error("blocked on empty waitgroup")
    end)
    op.perform(task)
    print("No wait test: ok")
end

local function test_simple()
    local wg = waitgroup.new()
    local numFibers = 5

    -- Spawn fibers and add to the waitgroup
    for _ = 1, numFibers do
        wg:add(1)
        fiber.spawn(function()
            sleep.sleep(math.random()) -- Simulate some work
            wg:done()
        end)
    end

    op.perform(
        wg:wait_op():wrap(function()
            error("waitgroup didn't block when it should have")
        end)
        :or_else(function() end)
    )

    wg:wait()
    print("Simple test: ok")
end

local function test_complex()
    local wg = waitgroup.new()
    local numFibers = 5

    local function one_sec_work(w)
        w:add(1)
        fiber.spawn(function()
            sleep.sleep(1) -- Simulate some work
            w:done()
        end)
    end

    local start = sc.monotime()

    -- Spawn fibers and add to the waitgroup
    for _ = 1, numFibers do one_sec_work(wg) end

    local done = false

    local extra_work_done = false
    local function extra_work()
        if not extra_work_done then
            extra_work_done = true
            one_sec_work(wg)
        end
    end

    while not done do
        op.perform(
            op.choice(
                wg:wait_op():wrap(function() done = true end),
                sleep.sleep_op(0.9):wrap(extra_work)
            )
        )
    end

    assert(sc.monotime() - start > 1.5)
    print("Complex test: ok")
end


local function main()
    test_nowait()
    test_simple()
    test_complex()
    fiber.stop()
end

-- Start the main function in fiber context
fiber.spawn(main)
fiber.main()

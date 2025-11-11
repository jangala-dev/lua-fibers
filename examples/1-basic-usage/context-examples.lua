package.path = "../../?.lua;../?.lua;" .. package.path

local fibers = require 'fibers'
local context = require 'fibers.context'
local sleep = require 'fibers.sleep'

local perform = require 'fibers.performer'.perform

-- Simulated work function
local function do_work(task_name, duration)
    print(task_name .. " started")
    sleep.sleep(duration)
    print(task_name .. " finished")
end

-- Sub-Task 1: Canceled by timeout
local function sub_task_1(ctx)
    local deadline_ctx, cancel = context.with_timeout(ctx, 5) -- Timeout after 5 seconds
    fibers.spawn(function()
        do_work("Sub-Task 1", 1) -- Simulates work for 10 seconds
        cancel("work_completed") -- Cancel the context (optional, as it will timeout)
    end)

    perform(deadline_ctx:done_op()) -- Wait for the context to be done
    print("Sub-Task 1 status: " .. (deadline_ctx:err() or "completed"))
end

-- Sub-Task 2: Waits for cancellation from the main task
local function sub_task_2(ctx)
    local cancel_ctx, cancel = context.with_cancel(ctx)
    fibers.spawn(function()
        do_work("Sub-Task 2", 3) -- Simulates longer work
        cancel("work_completed") -- Cancel the context when work is done
    end)

    perform(cancel_ctx:done_op()) -- Wait for the context to be done
    print("Sub-Task 2 status: " .. (cancel_ctx:err() or "completed"))
end

-- Main Task
local function main()
    local root_ctx = context.background() -- Root context
    local main_ctx, cancel = context.with_cancel(root_ctx) -- Root context
    fibers.spawn(function() sub_task_1(main_ctx) end)
    fibers.spawn(function() sub_task_2(main_ctx) end)

    sleep.sleep(2) -- Main task waits for 2 seconds before canceling Sub-Task 2
    cancel("main_canceled") -- This will propagate to Sub-Task 2
    sleep.sleep(1) -- Main task waits for 8 seconds before canceling Sub-Task 2
end

fibers.run(main)

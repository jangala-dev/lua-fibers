--- Tests the Context implementation.
print('testing: fibers.context')

-- look one level up
package.path = "../?.lua;" .. package.path

local context = require 'fibers.context'
local fiber = require 'fibers.fiber'
local op = require 'fibers.op'
local sleep = require 'fibers.sleep'

-- Test Background Context
local function test_background()
    local ctx = context.background()
    assert(ctx:value("key") == nil, "Background context should not have any values")
    print("test_background passed")
end

-- Test With Cancel Context
local function test_with_cancel()
    local parent = context.background()
    local ctx, cancel = context.with_cancel(parent)
    local child_ctx, _ = context.with_cancel(ctx)

    local is_cancelled = false
    fiber.spawn(function()
        op.perform(child_ctx:done_op())
        is_cancelled = true
    end)

    cancel()
    fiber.yield() -- Give time for cancellation to propagate

    assert(is_cancelled, "Child context should be cancelled when parent is cancelled")
    print("test_with_cancel passed")
end

-- Test With Value Context
local function test_with_value()
    local parent = context.background()
    local ctx_1 = context.with_value(parent, "key", "value")
    local ctx_2 = context.with_value(ctx_1, "another_key", "value")
    local ctx_3 = context.with_value(ctx_2, "key", "another_value")

    assert(ctx_1:value("key") == "value", "Context should have the correct value")
    assert(ctx_3:value("another_key") == "value", "Child context should inherit parent value")
    assert(ctx_3:value("key") == "another_value", "Child context should have its own value")
    print("test_with_value passed")
end

-- Test With Timeout Context
local function test_with_timeout()
    local parent = context.background()
    local ctx, _ = context.with_timeout(parent, 0.01)

    local is_cancelled = false
    fiber.spawn(function()
        op.perform(ctx:done_op())
        is_cancelled = true
    end)

    sleep.sleep(0.02) -- Give time for timeout to trigger

    assert(is_cancelled, "Context should be cancelled after timeout")
    print("test_with_timeout passed")
end

-- Test Custom Cause
local function test_custom_cause()
    local parent = context.background()
    local ctx, cancel = context.with_cancel(parent)
    local ctx_2, _ = context.with_cancel(ctx)
    local custom_cause = "Custom Cancel Reason"

    cancel(custom_cause)
    fiber.yield() -- Give time for cancellation to propagate

    assert(ctx:err() == custom_cause, "Context should have the custom cancel cause")
    assert(ctx_2:err() == custom_cause, "Child context should have the custom cancel cause")
    print("test_custom_cause passed")
end

local function test_cancel_on_with_value()
    local parent = context.background()
    local ctx, cancel = context.with_cancel(parent)
    local ctx_2, _ = context.with_value(ctx, "key", "value")
    local ctx_3, _ = context.with_value(ctx_2, "key2", "value2")

    cancel('cancelled')
    fiber.yield() -- Give time for cancellation to propagate

    assert(ctx:err() == 'cancelled', "Context should have cancel cause")
    assert(ctx_2:err() == 'cancelled', "Child context should have cancel cause")
    assert(ctx_2:value('key') == 'value', "Child context should have the value")
    assert(ctx_3:err() == 'cancelled', "Child context should have cancel cause")
    assert(ctx_3:value('key') == 'value', "Child context should have the value")
    assert(ctx_3:value('key2') == 'value2', "Child context should have the value")
end
-- Run all tests
fiber.spawn(function()
    test_background()
    test_with_cancel()
    test_with_value()
    test_with_timeout()
    test_custom_cause()
    test_cancel_on_with_value()

    print("All tests passed")
    fiber.stop()
end)

fiber.main()

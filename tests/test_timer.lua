--- Tests the Timer implementation.
print("test: fibers.timer")

-- look one level up
package.path = "../?.lua;" .. package.path

local timer = require 'fibers.timer'
local sc = require 'fibers.utils.syscall'

local function test_advance_time()
    local wheel = timer.new(10)
    local hour = 60 * 60
    local start_time = sc.monotime()
    wheel:advance(hour)
    local end_time = sc.monotime()
    print("Time to advance wheel by an hour: "..(end_time - start_time).." seconds")
end

local function test_event_scheduling(event_count)
    local wheel = timer.new(sc.monotime())
    local t = wheel.now
    local start_time = sc.monotime()
    for _=1, event_count do
        local dt = math.random()
        t = t + dt
        wheel:add_absolute(t, t)
    end
    local end_time = sc.monotime()
    print("Time to add "..event_count.." events: "..(end_time - start_time).." seconds")
end

local function test_event_expiration(event_count)
    local wheel = timer.new(sc.monotime())
    local last = 0
    local count = 0
    local check = {}
    local t = wheel.now

    function check:schedule(tw)
        local now = wheel.now
        assert(last <= tw)
        last, count = tw, count + 1
        assert(now - 1e-3 < tw)
        assert(tw < now + 1e-3)
    end

    for _=1, event_count do
        local dt = math.random()
        t = t + dt
        wheel:add_absolute(t, t)
    end

    local start_time = sc.monotime()
    wheel:advance(t + 1, check)
    local end_time = sc.monotime()
    print("Time to advance wheel to expire "..event_count.." events: "..(end_time - start_time).." seconds")
    assert(count == event_count)
end

local function test_large_intervals()
    local wheel = timer.new(sc.monotime())
    local far_future = 1e6 -- Far future time
    local event_triggered = false
    wheel:add_absolute(wheel.now + far_future, 'far_future_event')
    wheel:advance(wheel.now + far_future + 1e-3, {schedule = function() event_triggered = true end})
    assert(event_triggered, "Far future event was not triggered")
end

local function test_small_intervals()
    local wheel = timer.new(sc.monotime())
    local very_near_future = 1e-6 -- Very near future time
    local event_triggered = false
    wheel:add_absolute(wheel.now + very_near_future, 'near_future_event')
    wheel:advance(wheel.now + very_near_future + 1e-3, {schedule = function() event_triggered = true end})
    assert(event_triggered, "Near future event was not triggered")
end

local function test_advance_now_update()
    local wheel = timer.new(sc.monotime())
    local advance_time = 100 -- Advance by 100 seconds
    local start_time = wheel.now
    wheel:advance(start_time + advance_time)
    local expected_time = start_time + advance_time
    assert(wheel.now == expected_time, "Advance method failed to update 'now' correctly")
    print("Test for 'now' update in advance method passed")
end

-- Run tests
test_advance_time()
test_event_scheduling(1e4)
test_event_expiration(1e4)
test_large_intervals()
test_small_intervals()
test_advance_now_update()

print("All tests passed")

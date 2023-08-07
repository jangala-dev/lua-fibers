--- Tests the Timer implementation.
print("test: fibers.timer")

-- look one level up
package.path = "../?.lua;" .. package.path

local timer = require 'fibers.timer'
local sc = require 'fibers.utils.syscall'

local wheel = timer.new(10)

-- At millisecond precision, advancing the wheel by an hour shouldn't
-- take perceptible time.
local hour = 60*60
local start_time = sc.monotime()
wheel:advance(hour)
local end_time = sc.monotime()
print("Time to advance wheel by an hour: "..(end_time - start_time).." seconds")

local event_count = 1e4 -- Increase number of events for stress test
local t = wheel.now
start_time = sc.monotime()
for _=1,event_count do
    local dt = math.random()
    t = t + dt
    wheel:add_absolute(t, t) -- this is adding a simple number as the payload stored in the timer wheel
end
end_time = sc.monotime()
print("Time to add "..event_count.." events: "..(end_time - start_time).." seconds")

local last = 0
local count = 0
local check = {}
function check:schedule(t) -- in the call to wheel:advance below, this method is called and provided the payload inserted into the wheel, if it were really a scheduler it would resume the coroutine stored in the wheel??
    local now = wheel.now
    -- The timer wheel only guarantees ordering between ticks, not
    -- ordering within a tick.  It doesn't even guarantee insertion
    -- order within a tick.  However for this test we know that
    -- insertion order is preserved.
    assert(last <= t)
    last, count = t, count + 1
    -- Check that timers fire when they should.  
    assert(now - 1e-4 < t)
    assert(t < now + 1e-4)
end

start_time = sc.monotime()
wheel:advance(t+1, check)
end_time = sc.monotime()
print("Time to advance wheel to expire "..event_count.." events: "..(end_time - start_time).." seconds")

assert(count == event_count)

print("test: ok")

--- Tests the Scheduler implementation.
print("test: fibers.sched")

-- look one level up
package.path = "../?.lua;" .. package.path

local sched = require 'fibers.sched'
local sc = require 'fibers.utils.syscall'

-- Measure initialization time
local start_time = sc.monotime()
local scheduler = sched.new()
local end_time = sc.monotime()
print("Scheduler initialization time: " .. (end_time - start_time))

local count = 0
local function task_run(task)
    local now = scheduler:now()
    local t = task.scheduled
    count = count + 1
    -- Check that tasks run within a tenth a tick of when they should.
    -- Floating-point imprecisions can cause either slightly early or
    -- slightly late ticks.
    assert(now - scheduler.wheel.period*1.1 < t)
    assert(t < now + scheduler.wheel.period*0.1)
end

local event_count = 1e4
local t = scheduler:now()

-- Measure task scheduling time
start_time = sc.monotime()
for i=1,event_count do
    local dt = math.random()/1e2
    t = t + dt
    scheduler:schedule_at_time(t, {run=task_run, scheduled=t})
end
end_time = sc.monotime()
print("Task scheduling time: " .. (end_time - start_time)/event_count)

for now=scheduler:now(),t+1,scheduler.wheel.period do
    scheduler:run(now)
end

assert(count == event_count)

print("test: ok")
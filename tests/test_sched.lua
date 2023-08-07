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
local totalImprecision = 0

local function task_run(task)
    local now = scheduler:now()
    local t = task.scheduled
    count = count + 1
    local imprecision = math.abs(t - now)
    totalImprecision = totalImprecision + imprecision
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

while count < event_count do
    local nextEventTime = scheduler:next_wake_time()
    scheduler:run(nextEventTime)
end

assert(count == event_count)

local averageImprecision = totalImprecision / event_count
print("Average imprecision: " .. averageImprecision)

print("test: ok")
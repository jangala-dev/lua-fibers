-- fibers/sched.lua

-- Use of this source code is governed by the XXXXXXXXX license; see COPYING.

--- Core scheduler for fibre tasks.
-- @module fibers.sched

local sc    = require 'fibers.utils.syscall'
local timer = require 'fibers.timer'

local MAX_SLEEP_TIME = 10

local Scheduler = {}
Scheduler.__index = Scheduler

--- Create a new scheduler.
-- @tparam[opt] function get_time monotonic time source (defaults to sc.monotime)
local function new(get_time)
    local now_src = get_time or sc.monotime
    local now     = now_src()

    local ret = setmetatable({
        next         = {},             -- tasks runnable next turn
        cur          = {},             -- tasks being run this turn
        sources      = {},             -- timer, poller, etc.
        wheel        = timer.new(now), -- timer wheel on same clock
        maxsleep     = MAX_SLEEP_TIME,
        get_time     = now_src,
        event_waiter = nil,            -- optional poller
        done         = false,
    }, Scheduler)

    -- Timer source: advances wheel and schedules due tasks.
    local timer_task_source = { wheel = ret.wheel }

    function timer_task_source:schedule_tasks(sched, now_)
        self.wheel:advance(now_, sched)
    end

    -- Timers are not cleared; future timers simply never run once
    -- the scheduler stops.
    function timer_task_source:cancel_all_tasks()
    end

    ret:add_task_source(timer_task_source)
    return ret
end

--- Register a task source.
-- A source must support :schedule_tasks(sched, now).
function Scheduler:add_task_source(source)
    table.insert(self.sources, source)
    if source.wait_for_events then
        self.event_waiter = source
    end
end

--- Schedule a task object with a :run() method.
function Scheduler:schedule(task)
    table.insert(self.next, task)
end

function Scheduler:monotime()
    return self.get_time()
end

--- Last time seen by the timer wheel.
function Scheduler:now()
    return self.wheel.now
end

--- Schedule at an absolute time.
function Scheduler:schedule_at_time(t, task)
    self.wheel:add_absolute(t, task)
end

--- Schedule after a delay from the wheel's current time.
function Scheduler:schedule_after_sleep(dt, task)
    self.wheel:add_delta(dt, task)
end

--- Ask all sources to queue ready tasks.
function Scheduler:schedule_tasks_from_sources(now)
    for i = 1, #self.sources do
        self.sources[i]:schedule_tasks(self, now)
    end
end

--- Run all tasks currently scheduled.
-- If now is nil, uses monotonic time.
function Scheduler:run(now)
    if now == nil then
        now = self:monotime()
    end

    self:schedule_tasks_from_sources(now)

    self.cur, self.next = self.next, self.cur

    for i = 1, #self.cur do
        local task = self.cur[i]
        self.cur[i] = nil
        task:run()
    end
end

--- Time of the next thing that may need attention.
-- If there are runnable tasks, returns now() (i.e. do not sleep).
-- Otherwise delegates to the timer wheel, which returns either a time
-- or math.huge when empty.
function Scheduler:next_wake_time()
    if #self.next > 0 then
        return self:now()
    end
    return self.wheel:next_entry_time()
end

--- Block until the next event or timeout.
-- Uses an event_waiter (poller) if present, otherwise sleeps.
function Scheduler:wait_for_events()
    local now       = self:monotime()
    local next_time = self:next_wake_time()

    local timeout = math.min(self.maxsleep, next_time - now)
    if timeout < 0 then
        timeout = 0
    end

    if self.event_waiter then
        self.event_waiter:wait_for_events(self, now, timeout)
    else
        sc.floatsleep(timeout)
    end
end

--- Stop the main loop.
function Scheduler:stop()
    self.done = true
end

--- Main event loop.
function Scheduler:main()
    self.done = false
    repeat
        self:wait_for_events()
        self:run(self:monotime())
    until self.done
end

--- Attempt to drain runnable work and ask sources to cancel.
-- Does not clear timers; future timers remain queued but will never fire
-- once the scheduler is no longer driven.
function Scheduler:shutdown()
    for _ = 1, 100 do
        for i = 1, #self.sources do
            local src = self.sources[i]
            if src.cancel_all_tasks then
                src:cancel_all_tasks(self)
            end
        end

        if #self.next == 0 then
            return true
        end

        self:run()
    end
    return false
end

return {
    new = new
}

-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

-- File events.

local op = require 'fibers.op'
local fiber = require 'fibers.fiber'
local timer = require 'fibers.timer'
local sc = require 'fibers.utils.syscall'

local function days_in_year(y)
    return y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0) and 366 or 365
end

local function to_time(t)
    local new_t = {year = t.year, month=t.month, day=t.day, hour=t.hour, min=t.min, sec=t.sec}
    local time = os.time(new_t)
    local time_t = os.date("*t", time)
    return time, time_t
end

local function calculate_next(t, epoch)
    -- let's define some constants
    local periods = {"year", "month", "day", "hour", "min", "sec"}
    local default = {month=1, day=1, hour=0, min=0, sec=0}

    -- first let's make sure that the provided struct makes sense
    local inc_field
    if t.year then
        error("year should not be specified for a relative alarm")
    elseif t.yday then
        assert(not (t.month or t.wday or t.day), "neither month, weekday or day of month valid for day of year alarm")
        inc_field = "year"
    elseif t.month then
        assert(not t.wday, "day of week not valid for yearly alarm")
        inc_field = "year"
    elseif t.day then
        assert(not t.wday, "day of week not valid for monthly alarm")
        inc_field = "month"
    elseif t.wday then
        inc_field = "day"
    elseif t.hour then
        inc_field = "day"
    elseif t.minute then
        inc_field = "hour"
    elseif t.sec then
        inc_field = "minute"
    else
        error("a next alarm must specify at least one of yday, month, day, wday, hour, minute or sec")
    end

    -- let's construct the new date table
    local new_t = {}

    local now = os.date("*t", epoch)

    local default_switch = false
    for _, name in ipairs(periods) do
        if not default_switch and t[name] then default_switch = true end
        new_t[name] = not default_switch and now[name] or t[name] or default[name]
    end

    -- now let's get the struct we need
    local new_time, new_table = to_time(new_t)

    -- wday is a weird one and we need to renormalise
    if t.wday then
        local increment = (t.wday - new_table.wday + 7) % 7
        new_table.day = new_table.day + increment
        new_time, new_table = to_time(new_table)
    elseif t.yday then
        local no_days = days_in_year(new_table.year)
        local increment = (t.yday - new_table.yday + no_days) % no_days
        new_table.day = new_table.day + increment
        new_time, new_table = to_time(new_table)
    end

    if new_time < os.time() then
        new_table[inc_field] = new_table[inc_field] + 1
        new_time, new_table = to_time(new_table)
    end

    return new_time, new_table
end


local AlarmHandler = {}
AlarmHandler.__index = AlarmHandler

local function new_alarm_handler()
    local now = sc.realtime()
    return setmetatable(
        {
            realtime = false,
            abs_buffer = {},
            next_buffer = {},
            abs_timer = timer.new(now), -- Task list for absolute time scheduling
        }, AlarmHandler)
end

local installed_alarm_handler = nil

-- Installs the Alarm Handler into the current scheduler
local function install_alarm_handler()
    if not installed_alarm_handler then
        installed_alarm_handler = new_alarm_handler()
        fiber.current_scheduler:add_task_source(installed_alarm_handler)
    end
    return installed_alarm_handler
end

-- Uninstalls the Alarm Handler from the current scheduler
local function uninstall_alarm_handler()
    if installed_alarm_handler then
        for i, source in ipairs(fiber.current_scheduler.sources) do
            if source == installed_alarm_handler then
                table.remove(fiber.current_scheduler.sources, i)
                break
            end
        end
        installed_alarm_handler = nil
    end
end

function AlarmHandler:schedule_tasks(sched)
    local now = sc.realtime()

    self.abs_timer:advance(now, sched)

    while true do
        local next_time = self.abs_timer:next_entry_time() - now
        if next_time > sched.maxsleep then break end -- an empty timer will return 'inf' here so nil check not needed
        local task = self.abs_timer:pop()
        sched:schedule_after_sleep(next_time, task.obj)
    end
end

function AlarmHandler:block(time_to_start, t, task)
    if time_to_start < fiber.current_scheduler.maxsleep then
        print("about to sleep fiber for", time_to_start, "seconds")
        fiber.current_scheduler:schedule_after_sleep(time_to_start, task)
    else
        self.abs_timer:add_absolute(t, task)
    end
end

function AlarmHandler:achieve_realtime()
    print("realtime achieved")
    self.realtime = true
    local now = sc.realtime()
    -- Process buffered absolute tasks
    for _, buffered in ipairs(self.abs_buffer) do
        local time_to_start = buffered.t - now
        self:block(time_to_start, buffered.t, buffered.task)
    end
    -- Process next tasks
    for _, buffered in ipairs(self.next_buffer) do
        local next_time = calculate_next(buffered.t, now)
        local time_to_start = next_time - now
        self:block(time_to_start, next_time, buffered.task)
    end
    self.abs_buffer, self.next_buffer = {}, {} -- Clear the buffer
end

function AlarmHandler:absolute_op(t)
    local time_to_start
    local function try()
        if not self.realtime then return false end
        time_to_start = t - sc.realtime()
        if time_to_start < 0 then return true end
    end
    local function block(suspension, wrap_fn)
        local task = suspension:complete_task(wrap_fn)
        if not self.realtime then table.insert(self.abs_buffer, {t=t, task=task})
            return
        end
        self:block(time_to_start, t, task)
    end
    return op.new_base_op(nil, try, block)
end

function AlarmHandler:next_op(t)
    local function try()
        return false
    end
    local function block(suspension, wrap_fn)
        local task = suspension:complete_task(wrap_fn)
        if not self.realtime then table.insert(self.next_buffer, {t=t, task=task})
            return
        end
        local now = os.time()
        local target, _ = calculate_next(t, now)
        self:block(target-now, target, task)
    end
    return op.new_base_op(nil, try, block)
end

local function achieve_realtime()
    return assert(installed_alarm_handler):achieve_realtime()
end

local function absolute_op(t)
    return assert(installed_alarm_handler):absolute_op(t)
end

local function absolute(t)
    absolute_op(t):perform()
end

local function next_op(t)
    return assert(installed_alarm_handler):next_op(t)
end

local function next(t)
    next_op(t):perform()
end

-- Public API
return {
    install_alarm_handler = install_alarm_handler,
    uninstall_alarm_handler = uninstall_alarm_handler,
    achieve_realtime = achieve_realtime,
    absolute_op = absolute_op,
    absolute = absolute,
    next_op = next_op,
    next = next,
}


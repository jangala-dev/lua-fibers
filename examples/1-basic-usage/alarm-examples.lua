package.path = "../../?.lua;../?.lua;" .. package.path

local fiber = require 'fibers.fiber'
local alarm = require 'fibers.alarm'
local sc = require 'fibers.utils.syscall'

-- like pollio, the handler needs to be installed as a task source for the scheduler
alarm.install_alarm_handler()

-- until the user calls realtime_achieved() no alarms will return. absolute
-- alarms will return immediately if their time has elapsed, whereas next
-- alarms will be scheduled for their next instance
alarm.realtime_achieved()

local function set_alarm(t, number)
    local epoch, t_tab = alarm.calculate_next(t, sc.realtime())
    print("alarm "..number, "set to:", os.date("%A %d %B %Y at %H:%M:", epoch)..os.date("%S", epoch) + t_tab.msec/1e3)
    alarm.next(t)
    local _, sec, nsec = sc.realtime()
    print("alarm "..number, "fired at:", os.date("%A %d %B %Y at %H:%M:", sec)..os.date("%S", sec) + nsec/1e9)
end

fiber.spawn(function ()
    local _, sec, nsec = sc.realtime()
    print("Time now:", os.date("%A %d %B %Y at %H:%M:", sec)..os.date("%S", sec) + nsec/1e9, os.date("TZ: %z:", sec))

    local alarm_times = {
        {msec=233},
        {sec=12, msec=2},
        {min=41, sec=12},
        {hour=3, min=43},
        {day=17, hour=3, min=41, sec=12},
        {wday=1, hour=3, min=41},
        {yday=17, hour=3},
        {month=6},
    }

    for i, j in ipairs(alarm_times) do
        fiber.spawn(function ()
            set_alarm(j, i)
        end)
    end
end)

fiber.main()
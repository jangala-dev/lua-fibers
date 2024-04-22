--- Tests the Alarms implementation.
print('testing: fibers.alarm')

-- look one level up
package.path = "../?.lua;" .. package.path

local fiber = require 'fibers.fiber'
local alarm = require 'fibers.alarm'
local sleep = require 'fibers.sleep'
local sc = require 'fibers.utils.syscall'

alarm.install_alarm_handler()
alarm.realtime_achieved()

local function abs_test(secs)
    io.write("Starting Absolute test ... ")
    io.flush()
    local starttime = sc.realtime()
    alarm.absolute(starttime + secs)
    assert(sc.realtime() - starttime < secs + 0.1)
    print("complete!")
end

local function next_msec_test(t)
    io.write("Starting Millisecond test ... ")
    io.flush()
    local start = sc.realtime()
    alarm.next({msec=t})
    local epoch = sc.realtime()
    assert(epoch%1 * 1e3 - t < 50, "alarm didn't fire within 0.05 seconds of due time")
    assert(epoch - start < 1, "next Millisecond should fire within 1 second")
    print("complete!")
end

local function next_sec_test(secs)
    io.write("Starting Second test ... ")
    io.flush()
    local starttime = sc.realtime()
    local sleep_until = starttime + secs
    local t_table = os.date("*t", sleep_until)
    alarm.next({sec=t_table.sec})
    assert(sc.realtime() - starttime < secs + 0.1)
    print("complete!")
end

local function next_min_test(secs)
    io.write("Starting Minute test ... ")
    io.flush()
    local starttime = sc.realtime()
    local sleep_until = starttime + secs
    local t_table = os.date("*t", sleep_until)
    alarm.next({min=t_table.min, sec=t_table.sec})
    assert(sc.realtime() - starttime < secs + 0.1)
    print("complete!")
end

local function next_hour_test(secs)
    io.write("Starting Hour test ... ")
    io.flush()
    local starttime = sc.realtime()
    local sleep_until = starttime + secs
    local t_table = os.date("*t", sleep_until)
    alarm.next({hour=t_table.hour, min=t_table.min, sec=t_table.sec})
    assert(sc.realtime() - starttime < secs + 0.1)
    print("complete!")
end

local function next_day_test(secs)
    io.write("Starting Day test ... ")
    io.flush()
    local starttime = sc.realtime()
    local sleep_until = starttime + secs
    local t_table = os.date("*t", sleep_until)
    alarm.next({day=t_table.day,hour=t_table.hour, min=t_table.min, sec=t_table.sec})
    assert(sc.realtime() - starttime < secs + 0.1)
    print("complete!")
end

local function next_wday_test(secs)
    io.write("Starting Weekday test ... ")
    io.flush()
    local starttime = sc.realtime()
    local sleep_until = starttime + secs
    local t_table = os.date("*t", sleep_until)
    alarm.next({wday=t_table.wday,hour=t_table.hour, min=t_table.min, sec=t_table.sec})
    assert(sc.realtime() - starttime < secs + 0.1)
    print("complete!")
end

local function next_month_test(secs)
    io.write("Starting Month test ... ")
    io.flush()
    local starttime = sc.realtime()
    local sleep_until = starttime + secs
    local t_table = os.date("*t", sleep_until)
    alarm.next({month=t_table.month, day=t_table.day,hour=t_table.hour, min=t_table.min, sec=t_table.sec})
    assert(sc.realtime() - starttime < secs + 0.1)
    print("complete!")
end

local function next_yday_test(secs)
    io.write("Starting Yearday test ... ")
    io.flush()
    local starttime = sc.realtime()
    local sleep_until = starttime + secs
    local t_table = os.date("*t", sleep_until)
    alarm.next({yday=t_table.yday,hour=t_table.hour, min=t_table.min, sec=t_table.sec})
    assert(sc.realtime() - starttime < secs + 0.1)
    print("complete!")
end

local function buffer_test()
    io.write("Starting Buffer test ... ")
    io.flush()
    -- first absolutes - easy to test
    local t_sleep, t_sleep_before_realtime = 1, 2
    alarm.realtime_lost()
    fiber.spawn(function ()
        sleep.sleep(t_sleep_before_realtime)
        alarm.realtime_achieved()
    end)
    local start = sc.realtime()
    alarm.absolute(t_sleep)
    local finish = sc.realtime()
    assert(finish - start > 1.9 or finish - start < 2.1)
    -- next let's do nexts
    local msec_target = 333
    alarm.realtime_lost()
    fiber.spawn(function ()
        sleep.sleep(t_sleep_before_realtime)
        alarm.realtime_achieved()
    end)
    start = sc.realtime()
    alarm.next({msec=msec_target})
    finish = sc.realtime()
    assert(finish - start > 2) -- the event shouldn't fire until realtime_achieved is called
    assert(finish%1 - math.floor(finish) - msec_target < 50)
    print("complete!")
    print(finish)
end

fiber.spawn(function ()
    abs_test(2)
    next_msec_test(666)
    next_sec_test(2)
    next_min_test(2)
    next_hour_test(2)
    next_day_test(2)
    next_wday_test(2)
    next_month_test(2)
    next_yday_test(2)
    buffer_test()
    fiber.stop()
end)

fiber.main()

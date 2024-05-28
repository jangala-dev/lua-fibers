--- Tests the Alarms implementation.
print('testing: fibers.alarm')

-- look one level up
package.path = "../?.lua;" .. package.path

local fiber = require 'fibers.fiber'
local alarm = require 'fibers.alarm'
local sleep = require 'fibers.sleep'
local sc = require 'fibers.utils.syscall'

alarm.install_alarm_handler()
alarm.clock_synced()

local function abs_test(secs)
    io.write("Starting Absolute test ... ")
    io.flush()
    local starttime = sc.realtime()
    alarm.wait_absolute(starttime + secs)
    assert(sc.realtime() - starttime < secs + 0.1)
    print("complete!")
end

local function next_error()
    io.write("Starting Next Error test ... ")
    io.flush()
    local err = alarm.wait_next({year=2000})
    assert(err)
    print("complete!")
end

local function next_msec_test(t)
    io.write("Starting Millisecond test ... ")
    io.flush()
    local start = sc.realtime()
    alarm.wait_next({msec=t})
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
    local _, err = alarm.wait_next({sec=t_table.sec})
    assert(not err)
    assert(sc.realtime() - starttime < secs + 0.1)
    print("complete!")
end

local function next_min_test(secs)
    io.write("Starting Minute test ... ")
    io.flush()
    local starttime = sc.realtime()
    local sleep_until = starttime + secs
    local t_table = os.date("*t", sleep_until)
    alarm.wait_next({min=t_table.min, sec=t_table.sec})
    assert(sc.realtime() - starttime < secs + 0.1)
    print("complete!")
end

local function next_hour_test(secs)
    io.write("Starting Hour test ... ")
    io.flush()
    local starttime = sc.realtime()
    local sleep_until = starttime + secs
    local t_table = os.date("*t", sleep_until)
    alarm.wait_next({hour=t_table.hour, min=t_table.min, sec=t_table.sec})
    assert(sc.realtime() - starttime < secs + 0.1)
    print("complete!")
end

local function next_day_test(secs)
    io.write("Starting Day test ... ")
    io.flush()
    local starttime = sc.realtime()
    local sleep_until = starttime + secs
    local t_table = os.date("*t", sleep_until)
    alarm.wait_next({day=t_table.day,hour=t_table.hour, min=t_table.min, sec=t_table.sec})
    assert(sc.realtime() - starttime < secs + 0.1)
    print("complete!")
end

local function next_wday_test(secs)
    io.write("Starting Weekday test ... ")
    io.flush()
    local starttime = sc.realtime()
    local sleep_until = starttime + secs
    local t_table = os.date("*t", sleep_until)
    alarm.wait_next({wday=t_table.wday,hour=t_table.hour, min=t_table.min, sec=t_table.sec})
    assert(sc.realtime() - starttime < secs + 0.1)
    print("complete!")
end

local function next_month_test(secs)
    io.write("Starting Month test ... ")
    io.flush()
    local starttime = sc.realtime()
    local sleep_until = starttime + secs
    local t_table = os.date("*t", sleep_until)
    alarm.wait_next({month=t_table.month, day=t_table.day,hour=t_table.hour, min=t_table.min, sec=t_table.sec})
    assert(sc.realtime() - starttime < secs + 0.1)
    print("complete!")
end

local function next_yday_test(secs)
    io.write("Starting Yearday test ... ")
    io.flush()
    local starttime = sc.realtime()
    local sleep_until = starttime + secs
    local t_table = os.date("*t", sleep_until)
    alarm.wait_next({yday=t_table.yday,hour=t_table.hour, min=t_table.min, sec=t_table.sec})
    assert(sc.realtime() - starttime < secs + 0.1)
    print("complete!")
end

local function buffer_test()
    io.write("Starting Buffer test ... ")
    io.flush()
    -- first absolutes - easy to test
    local t_sleep, t_sleep_before_realtime = 1, 2
    alarm.clock_desynced()
    fiber.spawn(function ()
        sleep.sleep(t_sleep_before_realtime)
        alarm.clock_synced()
    end)
    local start = sc.realtime()
    alarm.wait_absolute(t_sleep)
    local finish = sc.realtime()
    assert(finish - start > 1.9 or finish - start < 2.1)
    -- next let's do nexts
    local msec_target = 333
    alarm.clock_desynced()
    fiber.spawn(function ()
        sleep.sleep(t_sleep_before_realtime)
        alarm.clock_synced()
    end)
    start = sc.realtime()
    alarm.wait_next({msec=msec_target})
    finish = sc.realtime()
    assert(finish - start > 2) -- the event shouldn't fire until clock_synced is called
    assert(finish%1 - math.floor(finish) - msec_target < 50)
    print("complete!")
end

local function validate_next_table_test()
    io.write("Starting validate_next_table test ... ")
    io.flush()

    local tests = {
        {
            input = {year=2027},
            expctd_err = "year should not be specified for a relative alarm"},
        {
            input = {yday=200},
            expctd_err = nil},
        {
            input = {yday=200, month=7},
            expctd_err = "neither month, weekday or day of month valid for day of year alarm"},
        {
            input = {month=12},
            expctd_err = nil},
        {
            input = {month=6, wday=3},
            expctd_err = "day of week not valid for yearly alarm"},
        {
            input = {day=15},
            expctd_err = nil},
        {
            input = {min=30, sec=45},
            expctd_err = nil},
        {
            input = {},
            expctd_err = "a next alarm must specify at least one of yday, month, day, wday, hour, minute, sec or msec"
        }
    }

    for _, test in ipairs(tests) do
        local _, result_error = alarm.validate_next_table(test.input)
        assert(
            result_error == test.expctd_err,
            string.format("expected %s, got %s", tostring(test.expctd_err), tostring(result_error))
        )
    end
    print("complete!")
end

local function test_next_calc()
    io.write("Starting Next Calculation test ... ")
    io.flush()

    local tests = {
        {
            description = "Testing Day Increment",
            epoch = os.time{year=2027, month=5, day=24, hour=0, min=0, sec=0},
            test_table = {day=25, hour=0, min=0, sec=0},
            expected_time = os.time{year=2027, month=5, day=25, hour=0, min=0, sec=0}
        },
        {
            description = "Testing Month Wraparound",
            epoch = os.time{year=3023, month=12, day=31, hour=23, min=59, sec=59},
            test_table = {month=1, day=1, hour=0, min=0, sec=0},
            expected_time = os.time{year=3024, month=1, day=1, hour=0, min=0, sec=0}
        },
        {
            description = "Testing Leap Year Day",
            epoch = os.time{year=2024, month=1, day=1, hour=0, min=0, sec=0},
            test_table = {month=2, day=29, hour=0, min=0, sec=0},
            expected_time = os.time{year=2024, month=2, day=29, hour=0, min=0, sec=0}
        },
        {
            description = "Testing Weekday Adjustment",
            epoch = os.time{year=2024, month=5, day=22, hour=12, min=43},  -- Wednesday
            test_table = {wday=6, min=12}, -- Targeting Friday
            expected_time = os.time{year=2024, month=5, day=24, hour=0, min=12, sec=0} -- The next Friday
        }
    }

    for _, test in ipairs(tests) do
        local calculated_time, _ = alarm.calculate_next(test.test_table, test.epoch)
        assert(calculated_time == test.expected_time, test.description .. ": Failed!")
    end

    print("complete!")
end

fiber.spawn(function ()
    abs_test(2)
    next_error()
    next_msec_test(666)
    next_sec_test(2)
    next_min_test(2)
    next_hour_test(2)
    next_day_test(2)
    next_wday_test(2)
    next_month_test(2)
    next_yday_test(2)
    buffer_test()
    validate_next_table_test()
    test_next_calc()
    fiber.stop()
end)

fiber.main()

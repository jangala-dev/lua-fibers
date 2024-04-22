-- look one level up
package.path = "../?.lua;" .. package.path

local fiber = require 'fibers.fiber'
local alarm = require 'fibers.alarm'
local sc = require 'fibers.utils.syscall'

alarm.install_alarm_handler()
alarm.achieve_realtime()

fiber.spawn(function ()
    local function abs_test(secs)
        print("about to sleep for", secs, "seconds")
        local now = sc.realtime()
        alarm.absolute(now + secs)
        print("waking from alarm after", sc.realtime() - now, "seconds")
    end

    local function next_test(secs)
        local sleep_until = os.time() + secs
        local t_table = os.date("*t", sleep_until)
        print("about to sleep until", t_table.hour..":"..t_table.min..":"..t_table.sec)
        alarm.next({hour=t_table.hour, min=t_table.min, sec=t_table.sec})
        local now_date = os.date("*t", sc.realtime())
        print("waking from alarm at", now_date.hour..":"..now_date.min..":"..now_date.sec)
    end

    abs_test(2)
    abs_test(11)
    print "about to start next tests"
    next_test(174)
    fiber.stop()
end)

fiber.main()

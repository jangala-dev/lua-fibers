package.path = "../../?.lua;../?.lua;" .. package.path

local waitgroup = require 'fibers.waitgroup'
local fiber = require 'fibers.fiber'
local sleep = require 'fibers.sleep'
local op = require 'fibers.op'
local go = require 'fibers.go'

local num_routines = 1000

local function main()

    local time = require 'fibers.utils.syscall'.monotonic_float
    local start = time()

	local wg1 = waitgroup.new()
	local wg2 = waitgroup.new()

    wg1:add(1)
	go(function()
		sleep.sleep(1)
		wg1:done()
	end)

    for i=1,num_routines do
        wg2:add(2)
        go(function ()
            wg1:wait()
            sleep.sleep(1)
            wg2:add(-2)
        end)
    end

    print("Waiting")
    wg2:wait()
    print("OK", time() - start, "seconds")
end

go(function()
    main()
    fiber.current_scheduler:stop()
end)
fiber.current_scheduler:main()
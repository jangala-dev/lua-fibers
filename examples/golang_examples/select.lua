package.path = "../../?.lua;../?.lua;" .. package.path

local channel = require 'fibers.channel'
local fiber = require 'fibers.fiber'
local sleep = require 'fibers.sleep'
local op = require 'fibers.op'

--- so simple to recreate Go's go
local function go(fn, args)
    fiber.spawn(function ()
        fn(unpack(args or {}))
    end)
end

local function main()

	local c1 = channel.new()
	local c2 = channel.new()

	go(function()
		sleep.sleep(1)
		c1:put("one")
	end)
	go(function()
		sleep.sleep(2)
		c2:put("two")
	end)

	for i=1,2 do
		op.choice(
			c1:get_operation():wrap(function(x)
				print(x.." on channel 1") 
			end),
			c2:get_operation():wrap(function(x) 
				print(x.." on channel 2") 
			end)
		):perform()
	end

    fiber.current_scheduler.done = true
end

fiber.spawn(main)
fiber.current_scheduler:main()

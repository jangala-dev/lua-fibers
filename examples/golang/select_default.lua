package.path = "../../?.lua;../?.lua;" .. package.path

local channel = require 'fibers.channel'
local fiber = require 'fibers.fiber'
local sleep = require 'fibers.sleep'
local op = require 'fibers.op'
local go = require 'fibers.go'

local function process(ch)
	sleep.sleep(10.5)
	ch:put("process successful")
end


local function main()
	local ch = channel.new()
	go(process, {ch})
	local loop = true
	while loop do
		sleep.sleep(1)
		op.choice(
			ch:get_operation():wrap(function(v)
				print("received value: ", v)
				-- We cannot use the keyword `return` here as Go (mis)uses, we
				-- signal using a simple local variable
				loop = false
			end)
		):default(
			function(x) print("no value received") end
		):perform()
	end
end

fiber.spawn(function()
    main()
    fiber.stop()
end)
fiber.main()
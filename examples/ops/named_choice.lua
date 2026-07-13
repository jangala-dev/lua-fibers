package.path = '../../src/?.lua;' .. package.path

local fibers = require 'fibers'
local sleep  = require 'fibers.sleep'

fibers.run(function ()
	local op = fibers.named_choice {
		slow = sleep.sleep_op(0.05):wrap(function () return 'S' end),
		fast = sleep.sleep_op(0.01):wrap(function () return 'F' end),
	}

	local name, v = fibers.perform(op)
	print(name, v) -- fast  F
end)

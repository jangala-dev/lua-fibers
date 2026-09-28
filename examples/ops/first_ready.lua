package.path = '../../src/?.lua;' .. package.path

local fibers = require 'fibers'
local sleep  = require 'fibers.sleep'

fibers.run(function ()
	local op = fibers.first_ready {
		sleep.sleep_op(0.05):wrap(function () return 'A' end),
		sleep.sleep_op(0.01):wrap(function () return 'B' end),
	}

	local i, v = fibers.perform(op)
	print(i, v) -- 2  B
end)

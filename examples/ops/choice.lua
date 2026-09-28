package.path = '../../src/?.lua;' .. package.path

local fibers = require 'fibers'
local sleep  = require 'fibers.sleep'

fibers.run(function ()
	local op = fibers.choice(
		sleep.sleep_op(0.05):wrap(function () return 'slow' end),
		sleep.sleep_op(0.01):wrap(function () return 'fast' end)
	)

	print(fibers.perform(op)) -- fast
end)

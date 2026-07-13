package.path = '../../src/?.lua;' .. package.path

local fibers = require 'fibers'
local sleep  = require 'fibers.sleep'

fibers.run(function ()
	local op = fibers.boolean_choice(
		sleep.sleep_op(0.05):wrap(function () return 'T' end),
		sleep.sleep_op(0.01):wrap(function () return 'F' end)
	)

	local ok, v = fibers.perform(op)
	print(ok, v) -- false  F
end)

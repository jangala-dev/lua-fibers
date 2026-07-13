package.path = '../../src/?.lua;' .. package.path

local fibers = require 'fibers'
local sleep  = require 'fibers.sleep'

fibers.run(function ()
	local op = fibers.race(
		{
			sleep.sleep_op(0.05):wrap(function () return 'A' end),
			sleep.sleep_op(0.01):wrap(function () return 'B' end),
		},
		function (i, v)
			return ('winner=%d'):format(i), v
		end
	)

	local which, v = fibers.perform(op)
	print(which, v) -- winner=2  B
end)

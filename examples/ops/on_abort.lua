package.path = '../../src/?.lua;' .. package.path

local fibers = require 'fibers'
local sleep  = require 'fibers.sleep'

fibers.run(function ()
	local slow = sleep.sleep_op(0.10)
		:on_abort(function () print('slow arm aborted') end)
		:wrap(function () return 'slow done' end)

	local fast = sleep.sleep_op(0.01):wrap(function () return 'fast done' end)

	print(fibers.perform(fibers.choice(slow, fast)))
end)

package.path = '../../src/?.lua;' .. package.path

local fibers = require 'fibers'
local sleep  = require 'fibers.sleep'

fibers.run(function ()
	local function acquire()
		print('acquire')
		return { id = 1 }
	end

	local function release(res, aborted)
		print('release', res.id, 'aborted=', aborted)
	end

	local function use(res)
		return sleep.sleep_op(0.10):wrap(function () return 'used', res.id end)
	end

	local protected = fibers.bracket(acquire, release, use)

	local op = fibers.choice(
		protected,
		sleep.sleep_op(0.01):wrap(function () return 'timeout' end)
	)

	print(fibers.perform(op))
end)

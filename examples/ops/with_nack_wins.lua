package.path = '../../src/?.lua;' .. package.path

local fibers = require 'fibers'
local op     = require 'fibers.op'
local cond   = require 'fibers.cond'
local sleep  = require 'fibers.sleep'

fibers.run(function ()
	local ev = op.with_nack(function (nack)
		local done = cond.new()

		fibers.spawn(function ()
			local which = fibers.perform(op.choice(
				nack:wrap(function () return 'nack' end),
				done:wait_op():wrap(function () return 'done' end)
			))
			if which == 'nack' then print('lost') end
		end)

		return sleep.sleep_op(0.05):wrap(function ()
			done:signal() -- this arm won; stop the watcher
			return 'slow done'
		end)
	end)

	print(fibers.perform(op.choice(
		ev,
		sleep.sleep_op(0.01):wrap(function () return 'fast done' end)
	)))
end)

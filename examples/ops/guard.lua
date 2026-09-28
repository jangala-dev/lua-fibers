package.path = '../../src/?.lua;' .. package.path

local fibers = require 'fibers'
local op     = require 'fibers.op'
local sleep  = require 'fibers.sleep'

fibers.run(function ()

	local function fake_upstream()
		local index, states = 1, { true, true, false, true }
		return function ()
			local retval = states[index]
			index = index + 1
			return retval
		end
	end

	local is_open = fake_upstream()

	local function breaker_op()
		return fibers.guard(function ()
			local ok_op = op.always("ok")
			local cooldown_op = sleep.sleep_op(0.1):wrap(function () return 'COOLDOWN' end)
			return is_open() and ok_op or cooldown_op
		end)
	end

	for i = 1, 4 do
		local ok = fibers.perform(breaker_op())
		print(i, ok)
	end
end)

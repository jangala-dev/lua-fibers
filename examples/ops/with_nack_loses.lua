package.path = '../../src/?.lua;' .. package.path

local fibers = require 'fibers'
local op     = require 'fibers.op'

fibers.run(function ()
	local ev = op.with_nack(function (nack)
		-- Arrange to observe nack
		return op.choice(
			op.never():wrap(function () return 'impossible' end),
			nack:wrap(function () return 'nacked' end)
		)
	end)

	local chosen = fibers.perform(op.choice(ev, op.always('other')))
	print(chosen) -- other   (and the nack branch is enabled, but only if someone perform)
end)

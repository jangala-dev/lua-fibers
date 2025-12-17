package.path = '../../src/?.lua;' .. package.path

local fibers = require 'fibers'

fibers.run(function ()
	local op = fibers.always('tea', 2)
	local a, b = fibers.perform(op)
	print(a, b) -- tea  2
end)

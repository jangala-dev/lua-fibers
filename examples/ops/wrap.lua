package.path = '../../src/?.lua;' .. package.path

local fibers = require 'fibers'

fibers.run(function ()
	local op = fibers.always(21):wrap(function (n) return n * 2 end)
	print(fibers.perform(op)) -- 42
end)

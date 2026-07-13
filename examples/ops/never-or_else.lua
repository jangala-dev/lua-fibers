package.path = '../../src/?.lua;' .. package.path

local fibers = require 'fibers'

fibers.run(function ()
	local op = fibers.never():or_else(function () return 'fallback' end)
	print(fibers.perform(op)) -- fallback
end)

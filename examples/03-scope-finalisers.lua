package.path = '../src/?.lua;' .. package.path

local fibers = require 'fibers'
local sleep  = require 'fibers.sleep'

fibers.run(function ()
	-- worker(s) runs inside a fresh child scope s.
	local function worker()
		local s = fibers.current_scope()

		s:finally(function ()
			print('finaliser 1 (outer)')
		end)

		s:finally(function ()
			print('finaliser 2 (inner)')
			-- This error is recorded as an additional failure.
			error('finaliser 2 failed')
		end)

		print('worker body starting')
		sleep.sleep(0.1)
		print('worker body raising error')
		error('worker body failed')
	end

	local status, rep, primary = fibers.run_scope(worker)

	print('status:', status)
	print('primary:', primary)
	print('extra failures:', #rep.extra_errors)
	for i, e in ipairs(rep.extra_errors) do
	print(('  [%d] %s'):format(i, tostring(e)))
	end
end)

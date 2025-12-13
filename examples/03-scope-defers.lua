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

	local status, err, def_errs = fibers.run_scope(worker)

	print('worker scope status:', status)
	print('worker scope primary error:', err)

	print('worker scope extra failures:', #def_errs)
	for i, e in ipairs(def_errs) do
		print(('  [%d] %s'):format(i, tostring(e)))
	end
end)

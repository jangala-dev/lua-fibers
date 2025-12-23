package.path = '../src/?.lua;' .. package.path

local fibers = require 'fibers'
local exec   = require 'fibers.io.exec'

local run       = fibers.run
local run_scope = fibers.run_scope

local function main()
	-- Put the subprocess in its own child scope so that any failure or
	-- cancellation is contained and reported at the boundary.
	local st, _, a, b, c = run_scope(function ()
		local cmd = exec.command(
			'sh', '-c',
			"echo 'hello from child process'; " ..
			'sleep 1; ' ..
			"echo 'goodbye from child process'"
		)

		-- Use status-first to avoid raising on cancellation/failure.
		local s = fibers.current_scope()
		local ost, output, proc_status, code, signal, perr = s:try(cmd:output_op())

		if ost ~= 'ok' then
			-- ost is 'failed' or 'cancelled'; output/proc_status/... are not meaningful here.
			-- Return a primary value for the boundary.
			return ost
		end

		print('[subprocess] status:', proc_status, 'code:', code, 'signal:', signal, 'err:', perr)
		print('[subprocess] output:')
		io.stdout:write(output)

		-- Return any values you want the boundary to carry on success.
		return proc_status, (code or signal), perr
	end)

	if st == 'ok' then
		local proc_status, code_or_sig, perr = a, b, c
		print('[root] child exec scope finished with:', st, proc_status, code_or_sig, perr)
	else
		local primary = a
		print('[root] child exec scope finished with:', st, primary)
	end

	-- report is available for diagnostics/telemetry if you want it:
	-- print('child scope report id:', report.id)
end

run(main)

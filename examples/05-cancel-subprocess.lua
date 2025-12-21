-- Demonstrates:
--   * Running an external process with fibers.io.exec
--   * Capturing stdout via a pipe
--   * Using boolean_choice to race process completion vs timeout
--   * Cancelling a scope on timeout and letting structured
--     concurrency clean up the subprocess and helper fibers
--
-- Notes for the current scope semantics:
--   * fibers.run_scope(fn, ...) returns:
--       - 'ok', packed_results_table, report
--       - 'failed'|'cancelled', primary, report
--   * Command cleanup runs as a scope finaliser and is non-interruptible.

package.path = '../src/?.lua;' .. package.path

local fibers = require 'fibers'
local exec   = require 'fibers.io.exec'
local sleep  = require 'fibers.sleep'

local run            = fibers.run
local spawn          = fibers.spawn
local perform        = fibers.perform
local boolean_choice = fibers.boolean_choice
local sleep_op       = sleep.sleep_op

----------------------------------------------------------------------
-- Main entry point
----------------------------------------------------------------------

local function main()
	print('[root] starting subprocess example')

	-- Run the subprocess and its helper fibers inside a child scope.
	-- Use run_scope so we can interpret status and primary at a clear boundary.
	local st, value_or_primary, _ = fibers.run_scope(function (s)
		print('[subscope] starting child process')

		------------------------------------------------------------------
		-- 1. Construct the command
		------------------------------------------------------------------

		local script = [[for i in 0 1 2 3 4 5 6 7 8 9; do echo "tick $i"; sleep 1; done]]

		local cmd = exec.command {
			'sh', '-c', script,
			stdin  = 'null',     -- no input
			stdout = 'pipe',     -- capture output
			stderr = 'inherit',  -- pass through
		}

		------------------------------------------------------------------
		-- 2. Reader fiber: drain stdout until EOF or error
		------------------------------------------------------------------

		spawn(function ()
			local out, serr = cmd:stdout_stream()
			if not out then
				print('[reader] no stdout stream:', serr)
				return
			end

			while true do
				local line, rerr = out:read('*l')
				if not line then
					if rerr then
						print('[reader] read error:', rerr)
					else
						print('[reader] EOF on stdout')
					end
					break
				end
				print('[reader]', line)
			end
		end)

		------------------------------------------------------------------
		-- 3. Race process completion against a timeout
		------------------------------------------------------------------

		local proc_won, status2, code, signal, err = perform(boolean_choice(
			cmd:run_op(),
			sleep_op(3.0)
		))

		if proc_won then
			print(('[subscope] command finished: status=%s code=%s signal=%s err=%s')
				:format(tostring(status2), tostring(code), tostring(signal), tostring(err)))
			return
		end

		------------------------------------------------------------------
		-- 4. Timeout: cancel the subscope
		------------------------------------------------------------------
		--
		-- This cancels the reader fiber and any other work in the scope.
		-- The Command’s scope finaliser will then perform a best-effort,
		-- non-interruptible shutdown and close any owned streams.
		--
		print('[subscope] timeout reached; cancelling subprocess scope')
		s:cancel('timeout')
	end)

	--------------------------------------------------------------------
	-- 5. Supervision boundary: interpret the outcome
	--------------------------------------------------------------------

	local reason = (st == 'ok') and nil or value_or_primary
	print('[root] subprocess scope completed; status:', st, 'reason:', reason)
end

run(main)

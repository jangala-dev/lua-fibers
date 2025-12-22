-- 06-scope-command-shared-pipe.lua
--
-- Demonstrates:
--   * parent scope owning a shared pipe
--   * a reader fiber in the parent scope draining that pipe
--   * a child scope boundary run as an Op (fibers.run_scope_op)
--   * racing the child scope against a timeout
--
-- Key point for the revised scope.run_op semantics:
--   The boundary body must PERFORM any Op it wants to run.
--   Returning an Op value merely returns that Op as a value; it does not execute it.

package.path = '../src/?.lua;' .. package.path

local fibers = require 'fibers'
local sleep  = require 'fibers.sleep'
local exec   = require 'fibers.io.exec'
local file   = require 'fibers.io.file'

local run_scope_op = fibers.run_scope_op
local named_choice = fibers.named_choice
local perform      = fibers.perform

local function main(parent_scope)
	----------------------------------------------------------------------
	-- Shared stream owned by the parent scope
	----------------------------------------------------------------------
	local r_stream, w_stream = file.pipe()

	-- Finaliser runs only after the scope has drained spawned fibers and joined children.
	parent_scope:finally(function ()
		print('[parent] finaliser: closing streams (runs after reader fiber has finished)')
		-- Best-effort close; guard against double-close from the body.
		pcall(function () assert(r_stream:close()) end)
		pcall(function () assert(w_stream:close()) end)
	end)

	----------------------------------------------------------------------
	-- Reader fiber in the parent scope (no explicit join/wait needed)
	----------------------------------------------------------------------
	do
		local ok, err = fibers.spawn(function ()
			print('[reader] started')
			while true do
				local line, e = perform(r_stream:read_line_op())
				if not line then
					print('[reader] EOF/error:', e)
					break
				end
				print('[reader] got:', line)
			end
			print('[reader] exiting')
		end)
		assert(ok, err)
	end

	----------------------------------------------------------------------
	-- Child scope as an Op: command writes ticks to the shared stream
	--
	-- IMPORTANT (revised semantics):
	--   run_scope_op yields:
	--     on ok:     'ok', report, ...body_results...
	--     on not ok: st,  report, primary
	--
	-- Therefore the child body must PERFORM cmd:run_op() and return its results.
	----------------------------------------------------------------------
	local child_scope_op = run_scope_op(function (_child_scope)
		print('[child] building child scope op')

		local script = [[for i in 0 1 2 3 4 5 6 7 8 9; do echo "tick $i"; sleep 1; done]]

		local cmd = exec.command {
			'sh', '-c', script,
			stdout = w_stream, -- shared stream from parent scope
		}

		print('[child] starting command')

		-- Run the command under the child scope and return its results as values.
		-- Assumed contract for cmd:run_op() when performed:
		--   cmd_st, code, signal, err
		local cmd_st, code, signal, cmd_err = fibers.perform(cmd:run_op())
		return cmd_st, code, signal, cmd_err
	end)

	----------------------------------------------------------------------
	-- Race the child scope against a timeout
	----------------------------------------------------------------------
	local ev = named_choice {
		child_scope_done = child_scope_op,
		timeout          = sleep.sleep_op(3),
	}

	-- named_choice returns: which, ...winner_results...
	local which, st, _, v1, v2, v3, v4 = perform(ev)

	if which == 'timeout' then
		print('[parent] choice: timeout (child scope was aborted and joined by run_scope_op)')
	else
		if st == 'ok' then
			local cmd_st, code, signal, cmd_err = v1, v2, v3, v4
			print('[parent] choice: child_scope_done',
				'cmd_st=', cmd_st,
				'code=', code,
				'signal=', signal,
				'err=', cmd_err
			)
			-- Report is available if you want to inspect child outcomes.
			-- print('[parent] child report id:', rep.id)
		else
			local primary = v1
			print('[parent] child scope ended:',
				'scope_st=', st,
				'primary=', primary
			)
		end
	end

	----------------------------------------------------------------------
	-- Important point:
	-- We do not wait for the reader fiber explicitly.
	--
	-- We close the writer to provoke EOF, then return from main.
	-- The surrounding scope join (performed by fibers.run) will wait
	-- until the reader fiber exits, then run finalisers, then return.
	----------------------------------------------------------------------
	pcall(function () assert(w_stream:close()) end)
	print('[parent] returning from main (reader may still be draining)')
end

fibers.run(main)

print('[outside] fibers.run returned (all scoped work, including reader fiber, has completed)')

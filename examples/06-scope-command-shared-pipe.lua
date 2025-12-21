package.path = '../src/?.lua;' .. package.path

local fibers = require 'fibers'
local sleep  = require 'fibers.sleep'
local exec   = require 'fibers.io.exec'
local file   = require 'fibers.io.file'

local run_scope_op = fibers.run_scope_op
local named_choice  = fibers.named_choice
local perform       = fibers.perform

local function main(parent_scope)
	----------------------------------------------------------------------
	-- Shared stream owned by the parent scope
	----------------------------------------------------------------------
	local r_stream, w_stream = file.pipe()

	-- Finaliser runs only after the scope has drained spawned fibers and joined children.
	parent_scope:finally(function ()
		print('[parent] finaliser: closing streams (runs after reader fiber has finished)')
		assert(r_stream:close())
		assert(w_stream:close())
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
	-- run_scope_op yields:
	--   scope_st, value_or_primary, report
	-- where on scope_st == 'ok', value_or_primary is a packed table of
	-- cmd:run_op() results: { [1]=cmd_st, [2]=code, [3]=signal, [4]=err, n=4 }
	----------------------------------------------------------------------
	local child_scope_op = run_scope_op(function (_)
		print('[child] building child scope op')

		local script = [[for i in 0 1 2 3 4 5 6 7 8 9; do echo "tick $i"; sleep 1; done]]

		local cmd = exec.command {
			'sh', '-c', script,
			stdout = w_stream, -- shared stream from parent scope
		}

		print('[child] starting command')
		return cmd:run_op()
	end)

	----------------------------------------------------------------------
	-- Race the child scope against a timeout
	----------------------------------------------------------------------
	local timeout_op = sleep.sleep_op(3):wrap(function ()
		return 'timeout'
	end)

	local ev = named_choice {
		child_scope_done = child_scope_op,
		timeout          = timeout_op,
	}

	local which, a, b, c = perform(ev)

	if which == 'timeout' then
		print('[parent] choice: timeout (child scope was aborted and joined by run_scope_op)')
	else
		local scope_st, value_or_primary, _ = a, b, c

		if scope_st == 'ok' then
			local vals = value_or_primary
			local cmd_st  = vals[1]
			local code    = vals[2]
			local signal  = vals[3]
			local cmd_err = vals[4]

			print('[parent] choice: child_scope_done',
				'cmd_st=', cmd_st,
				'code=', code,
				'signal=', signal,
				'err=', cmd_err
			)
			-- report is available if you want to inspect child outcomes
			-- print('[parent] child report id:', report.id)
		else
			print('[parent] child scope ended:',
				'scope_st=', scope_st,
				'primary=', value_or_primary
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
	assert(w_stream:close())
	print('[parent] returning from main (reader may still be draining)')
end

fibers.run(main)

print('[outside] fibers.run returned (all scoped work, including reader fiber, has completed)')

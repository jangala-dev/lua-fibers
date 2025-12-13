-- tests/test_io-exec.lua
--
-- Ad hoc tests and usage examples for fibers.io.exec.
--
-- Run as:  luajit test_io-exec.lua

print('testing: fibers.io.exec')

-- Look one level up for src modules.
package.path = '../src/?.lua;' .. package.path

local fibers = require 'fibers'
local exec   = require 'fibers.io.exec'
local op     = require 'fibers.op'
local sleep  = require 'fibers.sleep'
local poller = require 'fibers.io.poller'

----------------------------------------------------------------------
-- Helpers for shell-based FD / zombie counting
----------------------------------------------------------------------

local function warm_up_exec_backend()
	-- Run a trivial command once to force backend initialisation
	fibers.run(function ()
		local proc = exec.command {
			'sh', '-c', 'true',
			stdin  = 'null',
			stdout = 'null',
			stderr = 'null',
		}
		local status, code, _, err = fibers.perform(proc:run_op())
		assert(err == nil, 'warm-up wait error: ' .. tostring(err))
		assert(status == 'exited', 'warm-up status: ' .. tostring(status))
		assert(code == 0, 'warm-up exit code: ' .. tostring(code))
	end)
end

local function shell_capture(cmd)
	local p, perr = io.popen(cmd, 'r')
	assert(p, 'io.popen failed: ' .. tostring(perr))
	local out = p:read('*a') or ''
	p:close()
	return out
end

-- Force poller initialisation so its FDs are part of the baseline.
poller.get()

-- Force exec backend initialisation (self-pipe, reaper, etc.).
warm_up_exec_backend()

-- Count open FDs of the parent (luajit) process using /proc and $PPID.
local function get_fd_count_for_parent()
	local script = [=[
ls "/proc/$PPID/fd" 2>/dev/null | wc -l
]=]
	local ok, out = pcall(shell_capture, script)
	if not ok then
		return nil
	end
	local n = out:match('(%d+)')
	return n and tonumber(n) or nil
end

-- Count zombie children (state 'Z') of the parent (luajit) process.
-- Uses /proc/*/stat and awk; best-effort only.
local function get_zombie_count_for_parent()
	local script = [=[
parent="$PPID"
count=0
for stat in /proc/[0-9]*/stat; do
  [ -r "$stat" ] || continue
  set -- $(awk '{print $4, $3}' "$stat" 2>/dev/null)
  ppid="$1"
  state="$2"
  if [ "$ppid" = "$parent" ] && [ "$state" = "Z" ]; then
    count=$((count+1))
  fi
done
printf '%s\n' "$count"
]=]
	local ok, out = pcall(shell_capture, script)
	if not ok then
		return nil
	end
	local n = out:match('(%d+)')
	return n and tonumber(n) or nil
end

local baseline_fd_count     = get_fd_count_for_parent()
local baseline_zombie_count = get_zombie_count_for_parent()

print(('baseline: fds=%s zombies=%s')
	:format(tostring(baseline_fd_count), tostring(baseline_zombie_count)))

----------------------------------------------------------------------
-- Tests
----------------------------------------------------------------------

-- 1. Simple spawn: check we can see a non-zero exit code and no signal.
local function simple_exit_code()
	print('running: simple_exit_code')

	local proc = exec.command {
		'sh', '-c', 'exit 7',
		stdin  = 'null',
		stdout = 'null',
		stderr = 'null',
	}
	assert(proc, 'command creation failed')

	local status, code, sig, werr = fibers.perform(proc:run_op())
	assert(werr == nil, 'wait error: ' .. tostring(werr))
	assert(status == 'exited', "expected status 'exited', got " .. tostring(status))
	assert(sig == nil, 'expected no signal, got ' .. tostring(sig))
	assert(code == 7, 'expected exit code 7, got ' .. tostring(code))
end

-- 2. stdin/stdout pipes: cat echoes what we send.
local function stdin_stdout_pipe_round_trip()
	print('running: stdin_stdout_pipe_round_trip')

	local proc = exec.command {
		'sh', '-c', 'cat',
		stdin  = 'pipe',
		stdout = 'pipe',
		stderr = 'pipe',
	}
	assert(proc, 'command creation failed')

	local stdin_stream, sin_err   = proc:stdin_stream()
	local stdout_stream, sout_err = proc:stdout_stream()
	assert(stdin_stream and not sin_err, 'expected stdin stream, got error: ' .. tostring(sin_err))
	assert(stdout_stream and not sout_err, 'expected stdout stream, got error: ' .. tostring(sout_err))

	local msg = 'line1\nline2\n'
	local n, werr = stdin_stream:write(msg)
	assert(werr == nil, 'write error: ' .. tostring(werr))
	assert(n == #msg, 'short write: ' .. tostring(n))
	stdin_stream:close() -- send EOF

	local out, rerr = stdout_stream:read_all()
	assert(rerr == nil, 'read_all stdout error: ' .. tostring(rerr))
	assert(out == msg, ('unexpected echo: %q'):format(out))

	local status, code, sig, werr2 = fibers.perform(proc:run_op())
	assert(werr2 == nil, 'wait error: ' .. tostring(werr2))
	assert(status == 'exited', 'expected exited status')
	assert(sig == nil, 'expected no signal')
	assert(code == 0, 'expected exit 0')
end

-- 3. stderr as separate pipe vs stderr redirected to stdout.
local function stderr_pipe_vs_stderr_is_stdout()
	print('running: stderr_pipe_vs_stderr_is_stdout')

	-- Separate stderr.
	local proc1 = exec.command {
		'sh', '-c', 'echo out; echo err 1>&2',
		stdin  = 'null',
		stdout = 'pipe',
		stderr = 'pipe',
	}
	assert(proc1, 'spawn failed (separate stderr)')

	local out_stream1, oserr1 = proc1:stdout_stream()
	local err_stream1, eserr1 = proc1:stderr_stream()
	assert(out_stream1 and not oserr1, 'stdout stream error: ' .. tostring(oserr1))
	assert(err_stream1 and not eserr1, 'stderr stream error: ' .. tostring(eserr1))

	local out1, oerr1    = out_stream1:read_all()
	local errout1, eerr1 = err_stream1:read_all()
	assert(oerr1 == nil, 'stdout read error: ' .. tostring(oerr1))
	assert(eerr1 == nil, 'stderr read error: ' .. tostring(eerr1))
	assert(out1 == 'out\n', ('unexpected stdout: %q'):format(out1))
	assert(errout1 == 'err\n', ('unexpected stderr: %q'):format(errout1))

	fibers.perform(proc1:run_op())

	-- stderr merged into stdout.
	local proc2 = exec.command {
		'sh', '-c', 'echo out; echo err 1>&2',
		stdin  = 'null',
		stdout = 'pipe',
		stderr = 'stdout',
	}
	assert(proc2, 'spawn failed (stderr=stdout)')

	local out_stream2, oserr2 = proc2:stdout_stream()
	assert(out_stream2 and not oserr2, 'stdout stream error: ' .. tostring(oserr2))

	local err_stream2, _ = proc2:stderr_stream()
	-- When stderr is redirected to stdout, stderr_stream should return the same stream.
	assert(err_stream2 == out_stream2,
		'expected stderr_stream to return stdout stream when redirected')

	local merged, merr = out_stream2:read_all()
	assert(merr == nil, 'merged stdout read error: ' .. tostring(merr))
	assert(merged:match('out'), ("merged output missing 'out': %q"):format(merged))
	assert(merged:match('err'), ("merged output missing 'err': %q"):format(merged))

	fibers.perform(proc2:run_op())
end

-- 4. output_op: convenient capture of stdout plus status.
local function output_op_normal_completion()
	print('running: output_op_normal_completion')

	local proc = exec.command {
		'sh', '-c', 'echo bracket',
		stdin  = 'null',
		stdout = 'pipe',
		stderr = 'pipe',
	}
	assert(proc, 'command creation failed')

	local out, status, code, sig, err = fibers.perform(proc:output_op())
	assert(err == nil, 'output_op error: ' .. tostring(err))
	assert(status == 'exited', "expected status 'exited'")
	assert(code == 0, 'expected exit code 0')
	assert(sig == nil, 'expected no signal')

	-- /bin/sh echo will append a newline.
	assert(out == 'bracket\n', ('unexpected output from output_op: %q'):format(out))
end

-- 5. wait_op via run_op and a simple timeout pattern using boolean_choice.
local function wait_op_with_timeout_pattern()
	print('running: wait_op_with_timeout_pattern')

	local proc = exec.command {
		'/bin/sh', '-c', 'sleep 1',
		stdin  = 'null',
		stdout = 'null',
		stderr = 'null',
	}
	assert(proc, 'command creation failed')

	-- Race process completion vs timeout.
	local ev = op.boolean_choice(
		proc:run_op(),
		sleep.sleep_op(2.0)
	)

	local is_exit, status, code, sig, werr = fibers.perform(ev)
	assert(is_exit == true, 'process did not finish before timeout')
	assert(werr == nil, 'wait_op error: ' .. tostring(werr))
	assert(status == 'exited', "expected status 'exited'")
	assert(code == 0, 'expected exit code 0, got ' .. tostring(code))
	-- sig may be nil; we do not insist on value.

	-- Second wait should be immediate and return the same result.
	local status2, code2, sig2, werr2 = fibers.perform(proc:run_op())
	assert(status2 == status, 'status changed between waits')
	assert(code2 == code, 'code changed between waits')
	assert(sig2 == sig, 'signal changed between waits')
	assert(werr2 == nil, 'unexpected error on second wait: ' .. tostring(werr2))
end

-- 6. shutdown: terminate a long-running process (TERM then KILL if needed).
local function shutdown_long_running_process()
	print('running: shutdown_long_running_process')

	local proc = exec.command {
		'sh', '-c', 'while true; do sleep 1; done',
		stdin  = 'null',
		stdout = 'null',
		stderr = 'null',
	}
	assert(proc, 'command creation failed')

	local t0 = fibers.now()
	local _, _, _, err = fibers.perform(proc:shutdown_op(0.2))
	local t1 = fibers.now()

	-- Ensure we did not stall.
	assert((t1 - t0) < 5.0, ('shutdown took too long: %.3fs'):format(t1 - t0))

	-- For this ad hoc test we only insist that the process reached
	-- a terminal state. shutdown_op may surface backend details in `err`,
	-- which we treat as diagnostic rather than fatal here.
	local state, code_or_sig = proc:status()
	assert(
		state == 'exited' or state == 'signalled',
		('unexpected final state: %s (detail=%s, err=%s)')
		:format(tostring(state), tostring(code_or_sig), tostring(err))
	)
end

-- 7. Spawning as an Op for CML-shaped code (basic usage).
local function spawn_op_basic_usage()
	print('running: spawn_op_basic_usage')

	-- Build an Op that, when performed, creates a Command and returns it.
	local spawn_ev = op.guard(function ()
		local proc = exec.command {
			'sh', '-c', "printf 'via_op'",
			stdin  = 'null',
			stdout = 'pipe',
			stderr = 'pipe',
		}
		return op.always(proc)
	end)

	local proc = fibers.perform(spawn_ev)
	assert(proc, 'spawn_ev did not return a process')

	local stdout_stream, serr = proc:stdout_stream()
	assert(stdout_stream and not serr, 'stdout stream error: ' .. tostring(serr))

	local out, rerr = stdout_stream:read_all()
	assert(rerr == nil, 'read_all error: ' .. tostring(rerr))
	assert(out == 'via_op', ('unexpected stdout from spawn_ev: %q'):format(out))

	local status, code, sig, werr = fibers.perform(proc:run_op())
	assert(werr == nil, 'wait error: ' .. tostring(werr))
	assert(status == 'exited', "expected status 'exited'")
	assert(sig == nil, 'expected no signal')
	assert(code == 0, 'expected exit 0 from spawned process')
end

----------------------------------------------------------------------
-- 8. Torture: many short-lived processes in sequence.
----------------------------------------------------------------------

local function many_short_lived_processes_stress()
	print('running: many_short_lived_processes_stress')

	local N = 50

	for i = 1, N do
		local proc = exec.command {
			'sh', '-c', ("printf 'run-%d'; exit %d"):format(i, i % 256),
			stdin  = 'null',
			stdout = 'pipe',
			stderr = (i % 2 == 0) and 'null' or 'pipe',
		}
		assert(proc, ('command creation failed at iteration %d'):format(i))

		local stdout_stream, serr = proc:stdout_stream()
		assert(stdout_stream and not serr,
			('stdout stream error at iteration %d: %s'):format(i, tostring(serr)))

		local out, rerr = stdout_stream:read_all()
		assert(rerr == nil,
			('read_all error at iteration %d: %s'):format(i, tostring(rerr)))
		assert(out == ('run-%d'):format(i),
			('unexpected stdout at iteration %d: %q'):format(i, out))

		local status, code, sig, werr = fibers.perform(proc:run_op())
		assert(werr == nil,
			('wait error at iteration %d: %s'):format(i, tostring(werr)))
		assert(status == 'exited',
			("status not 'exited' at iteration %d: %s"):format(i, tostring(status)))
		assert(sig == nil,
			('signal not nil at iteration %d: %s'):format(i, tostring(sig)))
		assert(code == i % 256,
			('exit code mismatch at iteration %d: got %d, expected %d')
			:format(i, code, i % 256))
	end
end

----------------------------------------------------------------------
-- 9. Torture: large stdout via output_op.
----------------------------------------------------------------------

local function large_output_output_op_stress()
	print('running: large_output_output_op_stress')

	local lines = 5000
	local script = ([[
i=1
while [ $i -le %d ]; do
  echo "line-$i"
  i=$((i+1))
done
]]):format(lines)

	local proc = exec.command {
		'sh', '-c', script,
		stdin  = 'null',
		stdout = 'pipe',
		stderr = 'pipe',
	}
	assert(proc, 'command creation failed')

	local out, status, code, sig, err = fibers.perform(proc:output_op())
	assert(err == nil, 'output_op error: ' .. tostring(err))
	assert(status == 'exited', "expected status 'exited'")
	assert(code == 0, 'expected exit code 0')
	assert(sig == nil, 'expected no signal')

	local count = 0
	for line in out:gmatch('([^\n]*)\n') do
		if line ~= '' then
			count = count + 1
		end
	end
	assert(count == lines,
		('unexpected number of lines from large_output_output_op_stress: got %d, expected %d')
		:format(count, lines))

	assert(out:find('line-1', 1, true),
		"large output missing 'line-1'")
	assert(out:find('line-' .. tostring(lines), 1, true),
		'large output missing last line marker')
end

----------------------------------------------------------------------
-- Main
----------------------------------------------------------------------

local function main()
	simple_exit_code()
	stdin_stdout_pipe_round_trip()
	stderr_pipe_vs_stderr_is_stdout()
	output_op_normal_completion()
	wait_op_with_timeout_pattern()
	shutdown_long_running_process()
	spawn_op_basic_usage()
	many_short_lived_processes_stress()
	large_output_output_op_stress()
end

fibers.run(main)

local final_fd_count     = get_fd_count_for_parent()
local final_zombie_count = get_zombie_count_for_parent()

print(('final: fds=%s zombies=%s')
	:format(tostring(final_fd_count), tostring(final_zombie_count)))

if baseline_fd_count and final_fd_count then
	assert(final_fd_count == baseline_fd_count,
		('FD leak detected: baseline=%d final=%d')
		:format(baseline_fd_count, final_fd_count))
else
	print('FD leak check skipped (could not read /proc or count FDs)')
end

if baseline_zombie_count and final_zombie_count then
	assert(final_zombie_count <= baseline_zombie_count,
		('zombie leak detected: baseline=%d final=%d')
		:format(baseline_zombie_count, final_zombie_count))
else
	print('Zombie leak check skipped (could not read /proc or count zombies)')
end

print('test_io-exec.lua: all assertions passed')

-- tests/test_exec.lua
--
-- Ad hoc tests and usage examples for fibers.io.exec.
--
-- Run as:  luajit test_exec.lua

print("testing: fibers.io.exec")

-- Look one level up for src modules.
package.path = "../src/?.lua;" .. package.path

local fibers = require 'fibers'
local exec   = require 'fibers.io.exec'
local op     = require 'fibers.op'
local sleep  = require 'fibers.sleep'

----------------------------------------------------------------------
-- Tests
----------------------------------------------------------------------

-- 1. Simple spawn: check we can see a non-zero exit code and no signal.
local function simple_exit_code()
  print("running: simple_exit_code")

  local proc = exec.command{
    "sh", "-c", "exit 7",
    stdin  = "null",
    stdout = "null",
    stderr = "null",
  }
  assert(proc, "command creation failed")

  local status, code, sig, werr = fibers.perform(proc:run_op())
  assert(werr == nil,    "wait error: " .. tostring(werr))
  assert(status == "exited", "expected status 'exited', got " .. tostring(status))
  assert(sig == nil,     "expected no signal, got " .. tostring(sig))
  assert(code == 7,      "expected exit code 7, got " .. tostring(code))
end

-- 2. stdin/stdout pipes: cat echoes what we send.
local function stdin_stdout_pipe_round_trip()
  print("running: stdin_stdout_pipe_round_trip")

  local proc = exec.command{
    "sh", "-c", "cat",
    stdin  = "pipe",
    stdout = "pipe",
    stderr = "pipe",
  }
  assert(proc, "command creation failed")

  local stdin_stream, sin_err  = proc:stdin_stream()
  local stdout_stream, sout_err = proc:stdout_stream()
  assert(stdin_stream and not sin_err,  "expected stdin stream, got error: " .. tostring(sin_err))
  assert(stdout_stream and not sout_err, "expected stdout stream, got error: " .. tostring(sout_err))

  local msg = "line1\nline2\n"
  local n, werr = stdin_stream:write(msg)
  assert(werr == nil, "write error: " .. tostring(werr))
  assert(n == #msg,   "short write: " .. tostring(n))
  stdin_stream:close()  -- send EOF

  local out, rerr = stdout_stream:read_all()
  assert(rerr == nil, "read_all stdout error: " .. tostring(rerr))
  assert(out == msg,  ("unexpected echo: %q"):format(out))

  local status, code, sig, werr2 = fibers.perform(proc:run_op())
  assert(werr2 == nil, "wait error: " .. tostring(werr2))
  assert(status == "exited", "expected exited status")
  assert(sig == nil,        "expected no signal")
  assert(code == 0,         "expected exit 0")
end

-- 3. stderr as separate pipe vs stderr redirected to stdout.
local function stderr_pipe_vs_stderr_is_stdout()
  print("running: stderr_pipe_vs_stderr_is_stdout")

  -- Separate stderr.
  local proc1 = exec.command{
    "sh", "-c", "echo out; echo err 1>&2",
    stdin  = "null",
    stdout = "pipe",
    stderr = "pipe",
  }
  assert(proc1, "spawn failed (separate stderr)")

  local out_stream1, oserr1 = proc1:stdout_stream()
  local err_stream1, eserr1 = proc1:stderr_stream()
  assert(out_stream1 and not oserr1, "stdout stream error: " .. tostring(oserr1))
  assert(err_stream1 and not eserr1, "stderr stream error: " .. tostring(eserr1))

  local out1,   oerr1   = out_stream1:read_all()
  local errout1, eerr1  = err_stream1:read_all()
  assert(oerr1  == nil,       "stdout read error: " .. tostring(oerr1))
  assert(eerr1  == nil,       "stderr read error: " .. tostring(eerr1))
  assert(out1   == "out\n",   ("unexpected stdout: %q"):format(out1))
  assert(errout1 == "err\n",  ("unexpected stderr: %q"):format(errout1))

  fibers.perform(proc1:run_op())

  -- stderr merged into stdout.
  local proc2 = exec.command{
    "sh", "-c", "echo out; echo err 1>&2",
    stdin  = "null",
    stdout = "pipe",
    stderr = "stdout",
  }
  assert(proc2, "spawn failed (stderr=stdout)")

  local out_stream2, oserr2 = proc2:stdout_stream()
  assert(out_stream2 and not oserr2, "stdout stream error: " .. tostring(oserr2))

  local err_stream2, _ = proc2:stderr_stream()
  -- When stderr is redirected to stdout, stderr_stream should return the same stream.
  assert(err_stream2 == out_stream2,
    "expected stderr_stream to return stdout stream when redirected")

  local merged, merr = out_stream2:read_all()
  assert(merr == nil, "merged stdout read error: " .. tostring(merr))
  assert(merged:match("out"), ("merged output missing 'out': %q"):format(merged))
  assert(merged:match("err"), ("merged output missing 'err': %q"):format(merged))

  fibers.perform(proc2:run_op())
end

-- 4. output_op: convenient capture of stdout plus status.
local function output_op_normal_completion()
  print("running: output_op_normal_completion")

  local proc = exec.command{
    "sh", "-c", "echo bracket",
    stdin  = "null",
    stdout = "pipe",
    stderr = "pipe",
  }
  assert(proc, "command creation failed")

  local out, status, code, sig, err = fibers.perform(proc:output_op())
  assert(err == nil,        "output_op error: " .. tostring(err))
  assert(status == "exited", "expected status 'exited'")
  assert(code == 0,         "expected exit code 0")
  assert(sig == nil,        "expected no signal")

  -- /bin/sh echo will append a newline.
  assert(out == "bracket\n", ("unexpected output from output_op: %q"):format(out))
end

-- 5. wait_op via run_op and a simple timeout pattern using boolean_choice.
local function wait_op_with_timeout_pattern()
  print("running: wait_op_with_timeout_pattern")

  local proc = exec.command{
    "/bin/sh", "-c", "sleep 0.5",
    stdin  = "null",
    stdout = "null",
    stderr = "null",
  }
  assert(proc, "command creation failed")

  -- Race process completion vs timeout.
  local ev = op.boolean_choice(
    proc:run_op(),
    sleep.sleep_op(2.0)
  )

  local is_exit, status, code, sig, werr = fibers.perform(ev)
  assert(is_exit == true, "process did not finish before timeout")
  assert(werr == nil,     "wait_op error: " .. tostring(werr))
  assert(status == "exited", "expected status 'exited'")
  assert(code == 0,          "expected exit code 0, got " .. tostring(code))
  -- sig may be nil; we do not insist on value.

  -- Second wait should be immediate and return the same result.
  local status2, code2, sig2, werr2 = fibers.perform(proc:run_op())
  assert(status2 == status, "status changed between waits")
  assert(code2   == code,   "code changed between waits")
  assert(sig2    == sig,    "signal changed between waits")
  assert(werr2   == nil,    "unexpected error on second wait: " .. tostring(werr2))
end

-- 6. shutdown: terminate a long-running process (TERM then KILL if needed).
local function shutdown_long_running_process()
  print("running: shutdown_long_running_process")

  local proc = exec.command{
    "sh", "-c", "while true; do sleep 1; done",
    stdin  = "null",
    stdout = "null",
    stderr = "null",
  }
  assert(proc, "command creation failed")

  local t0 = fibers.now()
  local _, _, _, err = fibers.perform(proc:shutdown_op(0.2))
  local t1 = fibers.now()

  -- Ensure we did not stall.
  assert((t1 - t0) < 5.0, ("shutdown took too long: %.3fs"):format(t1 - t0))

  -- For this ad hoc test we only insist that the process reached
  -- a terminal state. shutdown_op may surface backend details in `err`,
  -- which we treat as diagnostic rather than fatal here.
  local state, code_or_sig = proc:status()
  assert(
    state == "exited" or state == "signalled",
    ("unexpected final state: %s (detail=%s, err=%s)")
      :format(tostring(state), tostring(code_or_sig), tostring(err))
  )
end

-- 7. Spawning as an Op for CML-shaped code (basic usage).
local function spawn_op_basic_usage()
  print("running: spawn_op_basic_usage")

  -- Build an Op that, when performed, creates a Command and returns it.
  local spawn_ev = op.guard(function()
    local proc = exec.command{
      "sh", "-c", "printf 'via_op'",
      stdin  = "null",
      stdout = "pipe",
      stderr = "pipe",
    }
    return op.always(proc)
  end)

  local proc = fibers.perform(spawn_ev)
  assert(proc, "spawn_ev did not return a process")

  local stdout_stream, serr = proc:stdout_stream()
  assert(stdout_stream and not serr, "stdout stream error: " .. tostring(serr))

  local out, rerr = stdout_stream:read_all()
  assert(rerr == nil,        "read_all error: " .. tostring(rerr))
  assert(out == "via_op",    ("unexpected stdout from spawn_ev: %q"):format(out))

  local status, code, sig, werr = fibers.perform(proc:run_op())
  assert(werr == nil,    "wait error: " .. tostring(werr))
  assert(status == "exited", "expected status 'exited'")
  assert(sig == nil,     "expected no signal")
  assert(code == 0,      "expected exit 0 from spawned process")
end

local function main()
  simple_exit_code()
  stdin_stdout_pipe_round_trip()
  stderr_pipe_vs_stderr_is_stdout()
  output_op_normal_completion()
  wait_op_with_timeout_pattern()
  shutdown_long_running_process()
  spawn_op_basic_usage()
end

fibers.run(main)

print("test_exec.lua: all assertions passed")

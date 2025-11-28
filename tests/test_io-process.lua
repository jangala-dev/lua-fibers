-- tests/test_process.lua
--
-- Ad hoc tests and usage examples for fibers.process.
--
-- Run as:  luajit test_process.lua

print("testing: fibers.io.process")

-- Look one level up for src modules.
package.path = "../src/?.lua;" .. package.path

local fibers  = require 'fibers'
local process = require 'fibers.io.process'
local op      = require 'fibers.op'
local sleep   = require 'fibers.sleep'

----------------------------------------------------------------------
-- Simple test harness
----------------------------------------------------------------------

local function run_test(name, fn)
  io.stderr:write("=== ", name, " ===\n")
  fibers.run(function(scope)
    fn(scope)
  end)
end

----------------------------------------------------------------------
-- Tests
----------------------------------------------------------------------

-- 1. Simple spawn: check we can see a non-zero exit code and no signal.
run_test("simple exit code", function()
  local proc, err = process.spawn{
    argv   = { "sh", "-c", "exit 7" },
    stdin  = "null",
    stdout = "null",
    stderr = "null",
  }
  assert(proc and not err, "spawn failed: " .. tostring(err))

  local _, code, sig, werr = proc:wait()
  assert(werr == nil, "wait error: " .. tostring(werr))
  assert(sig == nil,  "expected no signal, got " .. tostring(sig))
  assert(code == 7,   "expected exit code 7, got " .. tostring(code))

  proc:close()
end)

-- 2. stdin/stdout pipes: cat echoes what we send.
run_test("stdin/stdout pipe round-trip", function()
  local proc, err = process.spawn{
    argv   = { "sh", "-c", "cat" },
    stdin  = "pipe",
    stdout = "pipe",
    stderr = "pipe",
  }
  assert(proc and not err, "spawn failed: " .. tostring(err))
  assert(proc.stdin and proc.stdout, "expected stdin/stdout streams")

  local msg = "line1\nline2\n"
  local n, werr = proc.stdin:write(msg)
  assert(werr == nil,    "write error: " .. tostring(werr))
  assert(n == #msg,      "short write: " .. tostring(n))
  proc.stdin:close()     -- send EOF

  local out, rerr = proc.stdout:read_all()
  assert(rerr == nil, "read_all stdout error: " .. tostring(rerr))
  assert(out == msg,  ("unexpected echo: %q"):format(out))

  local _, code, sig, werr2 = proc:wait()
  assert(werr2 == nil, "wait error: " .. tostring(werr2))
  assert(sig == nil,   "expected no signal")
  assert(code == 0,    "expected exit 0")

  proc:close()
end)

-- 3. stderr as separate pipe vs stderr redirected to stdout.
run_test("stderr pipe vs stderr=stdout", function()
  -- Separate stderr.
  local proc1, err1 = process.spawn{
    argv   = { "sh", "-c", "echo out; echo err 1>&2" },
    stdin  = "null",
    stdout = "pipe",
    stderr = "pipe",
  }
  assert(proc1 and not err1, "spawn failed: " .. tostring(err1))

  local out1,  oerr1  = proc1.stdout:read_all()
  local errout1, eerr1 = proc1.stderr:read_all()
  assert(oerr1 == nil,   "stdout read error: " .. tostring(oerr1))
  assert(eerr1 == nil,   "stderr read error: " .. tostring(eerr1))
  assert(out1 == "out\n",   ("unexpected stdout: %q"):format(out1))
  assert(errout1 == "err\n", ("unexpected stderr: %q"):format(errout1))
  proc1:wait()
  proc1:close()

  -- stderr merged into stdout.
  local proc2, err2 = process.spawn{
    argv   = { "sh", "-c", "echo out; echo err 1>&2" },
    stdin  = "null",
    stdout = "pipe",
    stderr = "stdout",
  }
  assert(proc2 and not err2, "spawn failed: " .. tostring(err2))
  assert(proc2.stderr == nil, "expected stderr to be nil when redirected to stdout")

  local merged, merr = proc2.stdout:read_all()
  assert(merr == nil, "merged stdout read error: " .. tostring(merr))
  assert(merged:match("out"), ("merged output missing 'out': %q"):format(merged))
  assert(merged:match("err"), ("merged output missing 'err': %q"):format(merged))
  proc2:wait()
  proc2:close()
end)

-- 4. wait_op and a simple timeout pattern using boolean_choice.
run_test("wait_op with timeout pattern", function()
  local proc, err = process.spawn{
    argv   = { "/bin/sh", "-c", "sleep 0.5" },
    stdin  = "null",
    stdout = "null",
    stderr = "null",
  }
  assert(proc and not err, "spawn failed: " .. tostring(err))

  -- Correct use of boolean_choice: it injects the leading boolean itself.
  local ev = op.boolean_choice(
    proc:wait_op(),
    sleep.sleep_op(2.0)
  )

  local is_exit, status, code, _, werr = fibers.perform(ev)
  assert(is_exit == true, "process did not finish before timeout")
  assert(werr == nil, "wait_op error: " .. tostring(werr))
  assert(code == 0,   "expected exit code 0, got " .. tostring(code))
  -- sig may be nil or 0 depending on your syscall wrapper; we do not insist.

  -- Second wait should be immediate and return the same result.
  local status2, code2, sig2, werr2 = proc:wait()
  assert(status2 == status, "status changed between waits")
  assert(code2 == code,     "code changed between waits")
  assert(sig2 == sig2,      "signal comparison is trivial here")
  assert(werr2 == nil,      "unexpected error on second wait")

  proc:close()
end)

-- 5. shutdown: terminate a long-running process (TERM then KILL if needed).
run_test("shutdown long-running process", function()
  local proc, err = process.spawn{
    argv   = { "sh", "-c", "while true; do sleep 1; done" },
    stdin  = "null",
    stdout = "null",
    stderr = "null",
  }
  assert(proc and not err, "spawn failed: " .. tostring(err))

  local t0 = fibers.now()
  proc:shutdown(0.2)
  local t1 = fibers.now()

  assert((t1 - t0) < 5.0, "shutdown took too long")

  local state, code_or_sig = proc:status()
  assert(state == "exited" or state == "signalled",
    ("unexpected final state: %s (%s)"):format(tostring(state), tostring(code_or_sig)))
end)

-- 6. with_process: normal completion (bracket acquire/use/release).
run_test("with_process normal completion", function()
  local ev = process.with_process({
    argv   = { "sh", "-c", "echo bracket" },
    stdin  = "null",
    stdout = "pipe",
    stderr = "pipe",
  }, function(proc)
    return proc.stdout:read_line_op()
  end)

  local line, err = fibers.perform(ev)
  assert(err == nil, "with_process line error: " .. tostring(err))
  assert(line == "bracket", ("unexpected line: %q"):format(line))
end)

-- 7. with_process aborted via choice: losing arm triggers shutdown().
run_test("with_process aborted via choice", function()
  local long_spec = {
    argv   = { "sh", "-c", "sleep 10" },
    stdin  = "null",
    stdout = "null",
    stderr = "null",
  }

  local ev = op.boolean_choice(
    process.with_process(long_spec, function(proc)
      return proc:wait_op()
    end),
    sleep.sleep_op(0.1)
  )

  local is_first = fibers.perform(ev)
  -- We expect the timeout arm to win, so is_first should be false.
  assert(is_first == false, "expected timeout arm to win in boolean_choice")
end)

-- 8. spawn_op: spawning as an Op for CML-shaped code.
run_test("spawn_op basic usage", function()
  local spawn_ev = process.spawn_op{
    argv   = { "sh", "-c", "printf 'via_op'" },
    stdin  = "null",
    stdout = "pipe",
    stderr = "pipe",
  }

  local proc = fibers.perform(spawn_ev)
  assert(proc, "spawn_op did not return a process")

  local out, rerr = proc.stdout:read_all()
  assert(rerr == nil, "read_all error: " .. tostring(rerr))
  assert(out == "via_op", ("unexpected stdout from spawn_op: %q"):format(out))

  local _, code, sig, werr = proc:wait()
  assert(werr == nil, "wait error: " .. tostring(werr))
  assert(sig == nil,  "expected no signal")
  assert(code == 0,   "expected exit 0 from spawn_op process")

  proc:close()
end)

io.stderr:write("All process tests completed.\n")

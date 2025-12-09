package.path = "../src/?.lua;" .. package.path

local fibers   = require "fibers"
local sleep    = require "fibers.sleep"
local exec     = require "fibers.io.exec"
local file     = require "fibers.io.file"
local cond_mod = require "fibers.cond"

local scope_op     = fibers.scope_op
local named_choice = fibers.named_choice
local perform      = fibers.perform

local function main(parent_scope)
  ----------------------------------------------------------------------
  -- Shared stream owned by the parent scope
  ----------------------------------------------------------------------
  local r_stream, w_stream = file.pipe()

  -- Condition used to signal "reader has finished"
  local reader_done = cond_mod.new()

  -- Ensure streams are closed even if something goes wrong.
  parent_scope:defer(function()
    print("[parent] defer: closing shared streams")
    assert(r_stream:close()); assert(w_stream:close())
  end)

  ----------------------------------------------------------------------
  -- Reader fibre in the parent scope
  ----------------------------------------------------------------------
  fibers.spawn(function()
    print("[parent-reader] started")
    while true do
      local line, err = perform(r_stream:read_line_op())

      if not line then
        print("[parent-reader] done, err:", err)
        break
      end

      print("[parent-reader] got:", line)
    end

    -- Signal that the reader is finished.
    reader_done:signal()
  end)

  ----------------------------------------------------------------------
  -- Child scope as an Op: command writes ticks to the shared stream
  ----------------------------------------------------------------------
  local child_scope_op = scope_op(function()
    print("[child] building child scope op")

    local script = [[for i in 0 1 2 3 4 5 6 7 8 9; do echo "tick $i"; sleep 1; done]]

    local cmd = exec.command{
      "sh", "-c", script,
      stdout = w_stream,  -- shared stream from parent scope
    }

    print("[child] starting ticking command")
    -- Return an Op that completes when the process exits
    return cmd:run_op()
  end)

  ----------------------------------------------------------------------
  -- Race the child scope against a timeout
  ----------------------------------------------------------------------
  local ev = named_choice{
    child_scope_done = child_scope_op,    -- long-running command
    timeout          = sleep.sleep_op(3), -- after ~3 seconds
  }

  local which, status, code_or_sig, err = perform(ev)
  print("[parent] choice result:", which, status, code_or_sig, err)

  ----------------------------------------------------------------------
  -- Tear-down ordering:
  -- 1. The choice has returned, so the child scope_op has either:
  --    - completed (if child_scope_done won), or
  --    - been cancelled and fully joined (if timeout won).
  --    In both cases, the child process is no longer running.
  -- 2. We now close the writer end so the reader sees EOF.
  -- 3. We wait on reader_done to know the reader has finished.
  ----------------------------------------------------------------------
  assert(w_stream:close())

  -- Wait until the reader fibre has drained the stream and signalled completion.
  perform(reader_done:wait_op())
  print("[parent] reader has signalled completion")
end

fibers.run(main)

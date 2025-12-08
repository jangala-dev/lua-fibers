package.path = "../src/?.lua;" .. package.path

local fibers = require 'fibers'
local exec   = require 'fibers.io.exec'

local run     = fibers.run
local perform = fibers.perform
local run_scope = fibers.run_scope

local function main()
  -- Put the subprocess in its own child scope so that any failure or
  -- cancellation is neatly contained.
  local status, code_or_sig, err = run_scope(function()
    -- Simple shell pipeline: prints two lines with a pause.
    local cmd = exec.command(
      "sh", "-c",
      "echo 'hello from child process'; " ..
      "sleep 1; " ..
      "echo 'goodbye from child process'"
    )

    -- output_op():
    --   returns an Op that, when performed, yields:
    --     output : string (combined stdout)
    --     status : "ok" | "failed" | "cancelled" | "exited" | "signalled"
    --     code   : exit code or signal number (depending on status)
    --     signal : signal (if signalled)
    --     err    : string|nil backend error
    local output, proc_status, code, signal, perr = perform(cmd:output_op())

    print("[subprocess] status:", proc_status, "code:", code, "signal:", signal, "err:", perr)
    print("[subprocess] output:")
    io.stdout:write(output)

    return proc_status, code or signal, perr
  end)

  print("[root] child exec scope finished with:", status, code_or_sig, err)
end

run(main)

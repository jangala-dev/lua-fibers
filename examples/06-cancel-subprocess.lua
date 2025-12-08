-- Demonstrates:
--   * Running an external process with fibers.exec
--   * Capturing stdout via a pipe
--   * Using boolean_choice to race process completion vs timeout
--   * Cancelling a scope on timeout and letting structured
--     concurrency clean up the subprocess and helper fibres
--
-- Style:
--   * fibers.run(main) exposes the root scope as an argument.
--   * fibers.spawn(fn, ...) uses the current scope implicitly.
--   * Timeout is expressed algebraically via boolean_choice,
--     rather than a separate watchdog fibre.

package.path = "../src/?.lua;" .. package.path

local fibers = require "fibers"
local exec   = require "fibers.io.exec"
local sleep  = require "fibers.sleep"

local run           = fibers.run
local spawn         = fibers.spawn
local perform       = fibers.perform
local boolean_choice = fibers.boolean_choice
local current_scope = fibers.current_scope
local sleep_op      = sleep.sleep_op

----------------------------------------------------------------------
-- Main entry point
----------------------------------------------------------------------

run(function()
  print("[root] starting subprocess example")

  -- Run the subprocess and its helper fibres inside a child scope.
  -- We use run_scope so that we can interpret status and reason at
  -- a clear supervision boundary.
  local status, reason = fibers.run_scope(function()
    print("[subscope] starting child process")

    ------------------------------------------------------------------
    -- 1. Construct the command
    ------------------------------------------------------------------

    local script = [[for i in 0 1 2 3 4 5 6 7 8 9; do echo "tick $i"; sleep 1; done]]

    local cmd = exec.command{
      "sh", "-c", script,
      stdin  = "null",    -- no input
      stdout = "pipe",    -- capture output
      stderr = "inherit", -- pass through
    }

    ------------------------------------------------------------------
    -- 2. Reader fibre: drain stdout until EOF or error
    ------------------------------------------------------------------

    spawn(function()
      local out, serr = cmd:stdout_stream()
      if not out then
        print("[reader] no stdout stream:", serr)
        return
      end

      while true do
        local line, rerr = out:read("*l")
        if not line then
          if rerr then
            print("[reader] read error:", rerr)
          else
            print("[reader] EOF on stdout")
          end
          break
        end
        print("[reader]", line)
      end
    end)

    ------------------------------------------------------------------
    -- 3. Race process completion against a timeout
    ------------------------------------------------------------------
    --
    -- boolean_choice(opA, opB) returns:
    --   * true  + results from opA if A wins
    --   * false + results from opB if B wins
    --
    -- We wrap the two arms so that:
    --   * The command arm returns:   true,  status, code, signal, err
    --   * The timeout arm returns:   false
    --
    -- Note:
    --   * If the timeout wins, we do not try to handle cancellation
    --     inside the subscope. Instead we cancel the subscope from
    --     here and let its defers (including Command’s defer) run.
    --

    local proc_won, status2, code, signal, err = perform(boolean_choice(
      cmd:run_op():wrap(function(st, c, sig, e)
        return true, st, c, sig, e
      end),
      sleep_op(3.0):wrap(function()
        return false
      end)
    ))

    if proc_won then
      -- Process finished before the timeout and the scope has not
      -- yet been cancelled or failed.
      print(("[subscope] command finished: status=%s code=%s signal=%s err=%s")
        :format(tostring(status2), tostring(code), tostring(signal), tostring(err)))
      return
    end

    ------------------------------------------------------------------
    -- 4. Timeout: cancel the subscope
    ------------------------------------------------------------------
    --
    -- This cancels:
    --   * the reader fibre,
    --   * any other children in this scope, and
    --   * the Command’s scope defer will run _on_scope_exit(), which
    --     calls shutdown_op and waits for the process to die.
    --
    print("[subscope] timeout reached; cancelling subprocess scope")
    current_scope():cancel("timeout")
  end)

  --------------------------------------------------------------------
  -- 5. Supervision boundary: interpret the outcome
  --------------------------------------------------------------------

  print("[root] subprocess scope completed; status:", status, "reason:", reason)
end)

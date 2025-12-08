package.path = "../src/?.lua;" .. package.path

local fibers = require 'fibers'
local sleep  = require 'fibers.sleep'

local run            = fibers.run
local spawn          = fibers.spawn
local run_scope      = fibers.run_scope       -- Scope.run
local current_scope  = fibers.current_scope

local function main(root_scope)
  print("[root] starting; status:", root_scope:status())

  -- Create a child scope under the root.
  local status, err = run_scope(function()
    local s = current_scope()
    print("[child] scope created; status:", s:status())

    -- Failing worker.
    spawn(function()
      print("[child/worker1] will fail after 0.5s")
      sleep.sleep(0.5)
      error("simulated failure in worker1")
    end)

    -- Long-running worker; will be cancelled when sibling fails.
    spawn(function()
      local s2 = current_scope()
      print("[child/worker2] started; waiting for cancellation...")
      while true do
        -- Check whether the scope has already failed/cancelled.
        local st = s2:status()
        print("[child/worker2] observed scope status:", st)
        sleep.sleep(0.2)
      end
    end)

    -- This body returns once the child scope reaches a terminal state.
    -- No explicit wait is needed; run_scope handles join/defers.
  end)

  print("[root] child scope returned; status:", status, "error:", err)

  -- status will be "failed"; err will be the primary error from worker1.
end

run(main)

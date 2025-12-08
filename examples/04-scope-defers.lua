package.path = "../src/?.lua;" .. package.path

local fibers = require 'fibers'
local sleep  = require 'fibers.sleep'

fibers.run(function()
  -- worker(s) runs inside a fresh child scope s.
  local function worker()
    local s = fibers.current_scope()
    s:defer(function()
      print("defer 1 (outer)")
    end)

    s:defer(function()
      print("defer 2 (inner)")
      -- This error is recorded as an additional failure.
      error("defer 2 failed")
    end)

    print("worker body starting")
    sleep.sleep(0.1)
    print("worker body raising error")
    error("worker body failed")
  end

  local status, err = fibers.run_scope(worker)

  print("worker scope status:", status)
  print("worker scope primary error:", err)

  local extra = fibers.current_scope():failures()
  print("worker scope extra failures:", #extra)
  for i, e in ipairs(extra) do
    print(("  [%d] %s"):format(i, tostring(e)))
  end
end)

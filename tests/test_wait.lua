-- tests/test_wait.lua
print('testing: fibers.wait')

-- look one level up
package.path = "../src/?.lua;" .. package.path

local wait = require 'fibers.wait'
local op   = require 'fibers.op'
local fibers = require 'fibers'

----------------------------------------------------------------------
-- Simple assertion helper
----------------------------------------------------------------------

local function check(name, fn)
  io.write(name, " ... ")
  fn()
  io.write("ok\n")
end

----------------------------------------------------------------------
-- Waitset tests
----------------------------------------------------------------------

check("Waitset add/unlink/notify_all", function()
  local ws = wait.new_waitset()

  local scheduled = {}
  local fake_sched = {
    schedule = function(self, task)
      scheduled[#scheduled + 1] = task
    end,
  }

  local t1 = { run = function() end }
  local t2 = { run = function() end }

  local tok1 = ws:add("k", t1)
  local tok2 = ws:add("k", t2)

  assert(ws:size("k") == 2, "size after add should be 2")

  -- Unlink first token; bucket should still be non-empty.
  local emptied = tok1:unlink()
  assert(emptied == false, "unlink of first waiter should not empty bucket")
  assert(ws:size("k") == 1, "size after unlink should be 1")

  -- notify_all should schedule remaining task and clear bucket.
  ws:notify_all("k", fake_sched)
  assert(#scheduled == 1 and scheduled[1] == t2, "notify_all should schedule remaining waiter")
  assert(ws:is_empty("k"), "bucket should be empty after notify_all")

  -- Unlink on already-unlinked token is a no-op.
  emptied = tok1:unlink()
  assert(emptied == false, "unlink on stale token should be benign")
end)

check("Waitset notify_one", function()
  local ws = wait.new_waitset()

  local scheduled = {}
  local fake_sched = {
    schedule = function(self, task)
      scheduled[#scheduled + 1] = task
    end,
  }

  local t1 = { run = function() end }
  local t2 = { run = function() end }

  ws:add("k", t1)
  ws:add("k", t2)

  ws:notify_one("k", fake_sched)
  assert(#scheduled == 1, "notify_one should schedule exactly one task")
  assert(ws:size("k") == 1, "one waiter should remain after notify_one")

  ws:notify_one("k", fake_sched)
  assert(#scheduled == 2, "second notify_one should schedule second task")
  assert(ws:is_empty("k"), "bucket should be empty after second notify_one")
end)

----------------------------------------------------------------------
-- waitable tests
----------------------------------------------------------------------

-- 1. Fast path: step completes immediately; register() is never called.
check("waitable fast path (no blocking)", function()
  local step_calls = 0

  local function step()
    step_calls = step_calls + 1
    -- done == true, plus two result values.
    return true, "ok", 42
  end

  local register_called = false
  local function register(_task, _susp, _wrap)
    register_called = true
    error("register should not be called on fast path")
  end

  local ev = wait.waitable(register, step)

  local a, b = op.perform_raw(ev)
  assert(step_calls == 1, "step should be called once on fast path")
  assert(a == "ok" and b == 42, "results should be returned from step")
  assert(not register_called, "register should not be called on fast path")
end)

-- 2. Blocking path: first step() returns done=false, second returns done=true.
--    We run this under the scheduler so the suspension path is exercised.
check("waitable blocking path under scheduler", function()
  local step_calls = 0

  local function step()
    step_calls = step_calls + 1
    if step_calls == 1 then
      -- Not ready on first probe.
      return false
    end
    -- Ready on second probe.
    return true, "ready"
  end

  -- register(): in a real backend this would arrange for task:run()
  -- once the external condition changes. For this test we just run
  -- the task immediately, which still exercises the suspension logic.
  local function register(task, _suspension, _wrap)
    task:run()
    return { unlink = function() end }
  end

  local ev = wait.waitable(register, step)

  fibers.run(function()
    local res = fibers.perform(ev)
    assert(res == "ready", "waitable should eventually return 'ready'")
    assert(step_calls == 2, "step should be called twice (try + one wake)")
  end)
end)

io.write("All wait.lua tests completed\n")

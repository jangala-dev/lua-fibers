package.path = "../src/?.lua;" .. package.path

-- test_alarm.lua

print("testing: fibers.alarm")

local fibers    = require "fibers"
local sleep_mod = require "fibers.sleep"
local alarm_mod = require "fibers.alarm"

local sleep     = sleep_mod.sleep

local function approx_equal(a, b, eps)
  eps = eps or 1e-3
  return math.abs(a - b) <= eps
end

------------------------------------------------------------------------
-- Shared wall-clock for tests
------------------------------------------------------------------------

-- We control "wall clock" via this variable.
local wall_time = 0

local function now_fn()
  return wall_time
end

-- Install our test time source once. Alarm code only allows this once.
alarm_mod.set_time_source(now_fn)

------------------------------------------------------------------------
-- Test 1: basic one-shot alarm fires at expected time
------------------------------------------------------------------------

local function test_basic_alarm()
  print("[test_basic_alarm] start")

  wall_time = 0

  local calls = {}

  local function next_time(last, now)
    calls[#calls + 1] = { last = last, now = now }
    if last ~= nil then
      -- one-shot: only fire once
      return nil
    end
    -- Fire 0.1 seconds after "now"
    return now + 0.1
  end

  local al = alarm_mod.new{ next_time = next_time }

  local result = {}

  fibers.spawn(function()
    local ok, alarm, fired_epoch = fibers.perform(al:wait_op())
    result.ok    = ok
    result.alarm = alarm
    result.time  = fired_epoch
  end)

  -- Give the spawned fiber a chance to set up its wait
  sleep(0.01)

  -- Let 0.5s of monotonic time pass, which is comfortably > 0.1
  sleep(0.5)

  assert(result.ok == true, "basic alarm did not fire")
  assert(result.alarm == al, "basic alarm: unexpected alarm instance")
  assert(approx_equal(result.time, 0.1),
         ("basic alarm: expected fired_epoch ~= 0.1 (got %f)"):format(result.time))

  assert(#calls >= 1, "basic alarm: next_time was never called")
  assert(approx_equal(calls[1].now, 0),
         ("basic alarm: expected first now ~= 0 (got %f)"):format(calls[1].now))

  print("[test_basic_alarm] ok")
end

------------------------------------------------------------------------
-- Test 2: pre-emptive reschedule when time_changed() is called
------------------------------------------------------------------------

local function test_preemptive_reschedule()
  print("[test_preemptive_reschedule] start")

  wall_time = 0

  -- Offset controls how far in the future the alarm fires.
  local offset = 10

  local calls = {}

  local function next_time(last, now)
    calls[#calls + 1] = { last = last, now = now }
    if last ~= nil then
      -- one-shot for this test: only fire once
      return nil
    end
    return now + offset
  end

  local al = alarm_mod.new{ next_time = next_time }

  local result = {}

  fibers.spawn(function()
    local ok, alarm, fired_epoch = fibers.perform(al:wait_op())
    result.ok    = ok
    result.alarm = alarm
    result.time  = fired_epoch
  end)

  -- Allow the spawned fiber to start its wait and schedule the initial sleep
  sleep(0.01)

  -- At this point:
  --   wall_time == 0
  --   next_time(nil, 0) -> 0 + offset (=10)
  --   so the alarm is sleeping for dt = 10 seconds in monotonic time.

  -- Now simulate a civil-time change:
  --   * new notion of "wall now",
  --   * new offset (much shorter wait),
  --   * and notify alarms via time_changed().
  wall_time = 100    -- new wall "now"
  offset    = 1      -- next firing should now be at 101

  alarm_mod.time_changed()

  -- After time_changed(), the alarm's wait_op should:
  --   * wake from the clock-change branch,
  --   * clear _next_wall,
  --   * recompute next_wall from next_time(nil, 100) -> 101,
  --   * sleep for dt = 1,
  --   * then fire at last_fired_epoch == 101.

  -- Let enough monotonic time pass for the shorter dt=1 sleep to complete.
  sleep(2.0)

  assert(result.ok == true, "preemptive alarm did not fire")
  assert(result.alarm == al, "preemptive alarm: unexpected alarm instance")
  assert(approx_equal(result.time, 101),
         ("preemptive alarm: expected fired_epoch ~= 101 (got %f)"):format(result.time))

  -- Check that next_time was called at least twice:
  assert(#calls >= 2,
         ("preemptive alarm: expected at least 2 calls to next_time, got %d"):format(#calls))
  assert(approx_equal(calls[1].now, 0),
         ("preemptive alarm: first now ~= 0 (got %f)"):format(calls[1].now))
  assert(approx_equal(calls[2].now, 100),
         ("preemptive alarm: second now ~= 100 (got %f)"):format(calls[2].now))

  print("[test_preemptive_reschedule] ok")
end

------------------------------------------------------------------------
-- Test 3: multiple alarms reschedule in parallel
------------------------------------------------------------------------

local function test_multiple_alarms_reschedule()
  print("[test_multiple_alarms_reschedule] start")

  wall_time = 0

  local offset1 = 10
  local offset2 = 20

  local calls1, calls2 = {}, {}

  local function next_time1(last, now)
    calls1[#calls1 + 1] = { last = last, now = now }
    if last ~= nil then
      return nil
    end
    return now + offset1
  end

  local function next_time2(last, now)
    calls2[#calls2 + 1] = { last = last, now = now }
    if last ~= nil then
      return nil
    end
    return now + offset2
  end

  local al1 = alarm_mod.new{ next_time = next_time1 }
  local al2 = alarm_mod.new{ next_time = next_time2 }

  local r1, r2 = {}, {}

  fibers.spawn(function()
    local ok, alarm, t = fibers.perform(al1:wait_op())
    r1.ok, r1.alarm, r1.time = ok, alarm, t
  end)

  fibers.spawn(function()
    local ok, alarm, t = fibers.perform(al2:wait_op())
    r2.ok, r2.alarm, r2.time = ok, alarm, t
  end)

  -- Let both alarms set up their initial waits.
  sleep(0.01)

  -- Change civil time and offsets and notify once.
  wall_time = 100
  offset1   = 1
  offset2   = 2

  alarm_mod.time_changed()

  -- Enough monotonic time for both new sleeps (1 and 2 seconds).
  sleep(3.0)

  assert(r1.ok == true, "alarm1 did not fire")
  assert(r2.ok == true, "alarm2 did not fire")

  assert(r1.alarm == al1, "alarm1: unexpected alarm instance")
  assert(r2.alarm == al2, "alarm2: unexpected alarm instance")

  assert(approx_equal(r1.time, 101),
         ("alarm1: expected fired_epoch ~= 101 (got %f)"):format(r1.time))
  assert(approx_equal(r2.time, 102),
         ("alarm2: expected fired_epoch ~= 102 (got %f)"):format(r2.time))

  assert(#calls1 >= 2 and #calls2 >= 2, "multiple alarms: next_time not called enough times")

  assert(approx_equal(calls1[1].now, 0),  ("alarm1: first now ~= 0 (got %f)"):format(calls1[1].now))
  assert(approx_equal(calls1[2].now, 100),("alarm1: second now ~= 100 (got %f)"):format(calls1[2].now))
  assert(approx_equal(calls2[1].now, 0),  ("alarm2: first now ~= 0 (got %f)"):format(calls2[1].now))
  assert(approx_equal(calls2[2].now, 100),("alarm2: second now ~= 100 (got %f)"):format(calls2[2].now))

  print("[test_multiple_alarms_reschedule] ok")
end

------------------------------------------------------------------------
-- Test 4: repeated time_changed() while waiting
------------------------------------------------------------------------

local function test_repeated_time_changes()
  print("[test_repeated_time_changes] start")

  wall_time = 0

  local offset = 10
  local calls  = {}

  local function next_time(last, now)
    calls[#calls + 1] = { last = last, now = now }
    if last ~= nil then
      -- one-shot
      return nil
    end
    return now + offset
  end

  local al = alarm_mod.new{ next_time = next_time }

  local result = {}

  fibers.spawn(function()
    local ok, alarm, fired_epoch = fibers.perform(al:wait_op())
    result.ok    = ok
    result.alarm = alarm
    result.time  = fired_epoch
  end)

  -- Allow initial wait setup (now = 0, next_wall = 10).
  sleep(0.01)

  -- First change: bump wall_time to 100, keep offset = 10.
  wall_time = 100
  offset    = 10
  alarm_mod.time_changed()
  sleep(0.01)

  -- Second change: wall_time to 200, offset = 5.
  wall_time = 200
  offset    = 5
  alarm_mod.time_changed()
  sleep(0.01)

  -- Third change: wall_time to 300, offset = 1.
  wall_time = 300
  offset    = 1
  alarm_mod.time_changed()

  -- Final sleep long enough for the last dt = 1.
  sleep(2.0)

  assert(result.ok == true, "repeated-change alarm did not fire")
  assert(result.alarm == al, "repeated-change alarm: unexpected alarm instance")
  assert(approx_equal(result.time, 301),
         ("repeated-change alarm: expected fired_epoch ~= 301 (got %f)"):format(result.time))

  assert(#calls >= 3, ("repeated-change alarm: expected multiple next_time calls, got %d"):format(#calls))

  -- Check that we saw non-decreasing now values and that the last is ~300.
  local last_now = calls[1].now
  for i = 2, #calls do
    assert(calls[i].now >= last_now,
           ("repeated-change alarm: now not non-decreasing at call %d (prev=%f, now=%f)")
             :format(i, last_now, calls[i].now))
    last_now = calls[i].now
  end

  assert(approx_equal(last_now, 300),
         ("repeated-change alarm: last now ~= 300 (got %f)"):format(last_now))

  print("[test_repeated_time_changes] ok")
end

------------------------------------------------------------------------
-- Test 5: exhaustion behaviour still correct after reschedule
------------------------------------------------------------------------

local function test_exhaustion_after_reschedule()
  print("[test_exhaustion_after_reschedule] start")

  wall_time = 0

  local offset = 10
  local calls  = {}

  local function next_time(last, now)
    calls[#calls + 1] = { last = last, now = now }
    if last ~= nil then
      -- No further recurrences: one-shot alarm
      return nil
    end
    return now + offset
  end

  local al = alarm_mod.new{ next_time = next_time }

  local r1, r2 = {}

  fibers.spawn(function()
    -- First wait: should fire once.
    local ok1, alarm1, t1 = fibers.perform(al:wait_op())
    r1 = { ok = ok1, alarm = alarm1, time = t1 }

    -- Second wait: should give exhaustion notification.
    local ok2, why2, alarm2, last2 = fibers.perform(al:wait_op())
    r2 = { ok = ok2, why = why2, alarm = alarm2, last = last2 }
  end)

  -- Allow initial scheduling at now = 0, next_wall = 10.
  sleep(0.01)

  -- Change civil time and offset before the first firing.
  wall_time = 100
  offset    = 1
  alarm_mod.time_changed()

  -- Enough time for the recomputed dt = 1 sleep.
  sleep(2.0)

  -- Check first firing.
  assert(r1.ok == true, "exhaustion test: first firing did not occur")
  assert(r1.alarm == al, "exhaustion test: first firing alarm mismatch")
  assert(approx_equal(r1.time, 101),
         ("exhaustion test: expected first fired_epoch ~= 101 (got %f)"):format(r1.time))

  -- Check exhaustion notification.
  assert(r2.ok == false, "exhaustion test: second wait should report exhaustion")
  assert(r2.why == "no_more_recurrences",
         ("exhaustion test: expected reason 'no_more_recurrences', got %s"):format(tostring(r2.why)))
  assert(r2.alarm == al, "exhaustion test: second wait alarm mismatch")
  assert(approx_equal(r2.last, r1.time),
         ("exhaustion test: expected last == first fired time (got %f vs %f)")
           :format(r2.last or -1, r1.time or -1))

  -- Ensure next_time saw at least two calls (initial schedule and exhaustion computation).
  assert(#calls >= 2, ("exhaustion test: expected at least 2 next_time calls, got %d"):format(#calls))

  print("[test_exhaustion_after_reschedule] ok")
end

------------------------------------------------------------------------
-- Run tests under the fibers scheduler
------------------------------------------------------------------------

fibers.run(function()
  test_basic_alarm()
  test_preemptive_reschedule()
  test_multiple_alarms_reschedule()
  test_repeated_time_changes()
  test_exhaustion_after_reschedule()
end)

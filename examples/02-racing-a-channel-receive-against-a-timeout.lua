package.path = "../src/?.lua;" .. package.path

local fibers = require 'fibers'
local sleep  = require 'fibers.sleep'
local chan   = require 'fibers.channel'

local run     = fibers.run
local spawn   = fibers.spawn
local perform = fibers.perform
local choice  = fibers.choice

local function main()
  -- Buffered channel with capacity 1 so a late send will not block.
  local c = chan.new(1)

  -- Simulate a slow producer.
  spawn(function()
    sleep.sleep(3.0)
    print("[producer] sending result")
    c:put("result from producer")  -- will complete even if nobody is reading
    print("[producer] done")
  end)

  -- Build two Ops:
  --   1. Wait for a value from the channel.
  --   2. Wait for a timeout (2 seconds).
  local recv_op = c:get_op():wrap(function(v)
    return "value", v
  end)

  local timeout_op = sleep.sleep_op(2.0):wrap(function()
    return "timeout", nil
  end)

  local tag, payload = perform(choice(recv_op, timeout_op))

  if tag == "value" then
    print("[main] got channel value:", payload)
  elseif tag == "timeout" then
    print("[main] timed out before producer responded")
  else
    print("[main] unexpected tag:", tag, payload)
  end

  print("[main] returning from Example 3")
end

run(main)

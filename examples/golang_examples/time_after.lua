package.path = "../../?.lua;../?.lua;" .. package.path

local channel = require 'fibers.channel'
local fiber = require 'fibers.fiber'
local sleep = require 'fibers.sleep'
local op = require 'fibers.op'

local function go(fn, args)
  fiber.spawn(function ()
    fn(unpack(args or {}))
  end)
end

local function complete()
  sleep.sleep(10)
  print("Complete")
  fiber.current_scheduler.done = true
end

local function time_after_operation(t)
  local function try()
    return false
  end

  local function block(suspension, wrap_fn)
    suspension.sched:schedule_after_sleep(t, suspension:complete_task(wrap_fn))
 end
  
  return op.new_base_op(nil, try, block)
end

local function handler(worker)
  while true do
    op.choice(
			worker.chan1:get_operation():wrap(function(msg)
        print(msg)
			end),
			worker.chan2:get_operation():wrap(function(msg) 
        print(msg)
			end),
      time_after_operation(1):wrap(function()
        print("Time after")
      end)
		):perform()
  end
end

local function worker(worker, sleepTime)
  while true do
    worker.chan1:put("message from " .. worker.name .. " on channel 1")
    worker.chan2:put("message from " .. worker.name .. " on channel 2")
    sleep.sleep(sleepTime)
  end
end

local function main()
  local worker1 = {
    chan1 = channel.new(),
    chan2 = channel.new(),
    name = "John"
  }

  go(handler, { worker1 })
  go(worker, { worker1, 2 })
  go(complete)
end

fiber.spawn(main)
fiber.current_scheduler:main()
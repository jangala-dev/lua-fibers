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

local function handler(worker)
  while true do
    op.choice(
			worker.chan1:get_operation():wrap(function(msg)
        print(msg)
			end),
			worker.chan2:get_operation():wrap(function(msg) 
        print(msg)
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
  local worker2 = {
    chan1 = channel.new(),
    chan2 = channel.new(),
    name = "Rich"
  }
  
  go(handler, { worker1 })
  go(handler, { worker2 })
  go(worker, { worker1, 5 })
  go(worker, { worker2, 1 })
  go(complete)
  fiber.current_scheduler:main() 
end

fiber.spawn(main)
fiber.current_scheduler:main()
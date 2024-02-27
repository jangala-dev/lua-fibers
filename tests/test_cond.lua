--- Tests the Cond implementation.
print('testing: fibers.cond')

-- look one level up
package.path = "../?.lua;" .. package.path

local cond = require 'fibers.cond'
local fiber = require 'fibers.fiber'
local sleep = require 'fibers.sleep'
local sc = require 'fibers.utils.syscall'

local equal = require 'fibers.utils.helper'.equal

local c, log = cond.new(), {}
local function record(x) table.insert(log, x) end

fiber.spawn(function() record('a'); c:wait(); record('b') end)
fiber.spawn(function() record('c'); c:signal(); record('d') end)
assert(equal(log, {}))
fiber.current_scheduler:run()
assert(equal(log, {'a', 'c', 'd'}))
fiber.current_scheduler:run()
assert(equal(log, {'a', 'c', 'd', 'b'}))

fiber.spawn(function()
   local fiber_count = 1e3
   for _=1, fiber_count do
      fiber.spawn(function() c:wait(); end)
   end

   sleep.sleep(1)

   local start_time = sc.monotime()
   c:signal()
   local end_time = sc.monotime()

   print("Time taken to signal fiber: ", (end_time - start_time)/fiber_count)
   fiber.stop()
end)

fiber.main()
print('test: ok')

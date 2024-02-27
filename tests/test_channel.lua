--- Tests the Channel implementation.
print('testing: fibers.channel')

-- look one level up
package.path = "../?.lua;" .. package.path


local channel = require 'fibers.channel'
local fiber = require 'fibers.fiber'
local sc = require 'fibers.utils.syscall'
local equal = require 'fibers.utils.helper'.equal

local ch, log = channel.new(), {}
local function record(x) table.insert(log, x) end

fiber.spawn(function() record('a'); record(ch:get()) end)
fiber.spawn(function() record('b'); ch:put('c'); record('d') end)
assert(equal(log, {}))
fiber.current_scheduler:run()
-- One turn: first fiber ran, suspended, then second fiber ran,
-- completed first, and continued self to end.
assert(equal(log, {'a', 'b', 'd'}))
fiber.current_scheduler:run()
-- Next turn schedules first fiber and finishes.
assert(equal(log, {'a', 'b', 'd', 'c'}))

log = {}
fiber.spawn(function() record('b'); ch:put('c'); record('d') end)
fiber.spawn(function() record('a'); record(ch:get()) end)
assert(equal(log, {}))
fiber.current_scheduler:run()
-- Reversed order.
assert(equal(log, {'b', 'a', 'c'}))
fiber.current_scheduler:run()
assert(equal(log, {'b', 'a', 'c', 'd'}))

-- Performance test.
local message_count = 1e4
local done = 0

fiber.spawn(function ()
   for _=0, message_count do done = done + ch:get() end
end)

fiber.spawn(function ()
   for _=0, message_count do ch:put(1) end
end)

local start_time = sc.monotime()
for _=0, message_count do fiber.current_scheduler:run() end
local end_time = sc.monotime()

print("Time taken per send/receive: ", (end_time - start_time)/(message_count*2))

assert(done == message_count)

print('test: ok')

--- Tests the Fiber implementation.
print('testing: fibers.fiber')

-- look one level up
package.path = "../?.lua;" .. package.path

local fiber = require 'fibers.fiber'
local sc = require 'fibers.utils.syscall'
local equal = require 'fibers.utils.helper'.equal

local defscope = fiber.defscope

local log = {}
local function record(x) table.insert(log, x) end

local fn1 = function ()
    local defer, scope = defscope()
    scope(function()
        defer(record, 'd')
        record('b'); fiber.yield()
        record('c'); fiber.yield()
        error({'e'})
        record('z'); fiber.yield() -- will never be called
    end)() -- calls an anonymous scope, could name and call instead
end

fiber.spawn(function ()
    record('a')
    fiber.spawn(function()
        local ok, res = pcall(fn1); fiber.yield()
        assert(not ok and res)
        record(res[1])
    end)
end)

assert(equal(log, {}))
fiber.current_scheduler:run()
assert(equal(log, {'a'}))
fiber.current_scheduler:run()
assert(equal(log, {'a', 'b'}))
fiber.current_scheduler:run()
assert(equal(log, {'a', 'b', 'c'}))
fiber.current_scheduler:run()
assert(equal(log, {'a', 'b', 'c', 'd'}))
fiber.current_scheduler:run()
assert(equal(log, {'a', 'b', 'c', 'd', 'e'}))
fiber.current_scheduler:run()
assert(equal(log, {'a', 'b', 'c', 'd', 'e'}))

-- Test performance
local start_time = sc.monotime()
local fiber_count = 1e4
local count = 0
local function inc()
    count = count + 1
end
for i=1, fiber_count do
    fiber.spawn(function()
        inc(); fiber.yield(); inc(); fiber.yield(); inc()
    end)
end

local end_time = sc.monotime()
print("Fiber creation time: "..(end_time - start_time)/fiber_count)

start_time = sc.monotime()
for i=1,3*fiber_count do -- run fibers, each fiber yields 3 times
    fiber.current_scheduler:run()
end
end_time = sc.monotime()
print("Fiber operation time: "..(end_time - start_time)/(2*3*fiber_count))

assert(count == 3*fiber_count)

print('test: ok')

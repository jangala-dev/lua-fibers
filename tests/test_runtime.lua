--- Tests the Fiber implementation.
print('testing: fibers.fiber')

-- look one level up
package.path = "../src/?.lua;" .. package.path

local runtime = require 'fibers.runtime'
local sc = require 'fibers.utils.syscall'
local equal = require 'fibers.utils.helper'.equal

local log = {}
local function record(x) table.insert(log, x) end

runtime.spawn(function()
    record('a'); runtime.yield(); record('b'); runtime.yield(); record('c')
end)

assert(equal(log, {}))
runtime.current_scheduler:run()
assert(equal(log, {'a'}))
runtime.current_scheduler:run()
assert(equal(log, {'a', 'b'}))
runtime.current_scheduler:run()
assert(equal(log, {'a', 'b', 'c'}))
runtime.current_scheduler:run()
assert(equal(log, {'a', 'b', 'c'}))

-- Test performance
local start_time = sc.monotime()
local fiber_count = 1e4
local count = 0
local function inc()
    count = count + 1
end
for _=1, fiber_count do
    runtime.spawn(function()
        inc(); runtime.yield(); inc(); runtime.yield(); inc()
    end)
end

local end_time = sc.monotime()
print("Fiber creation time: "..(end_time - start_time)/fiber_count)

start_time = sc.monotime()
for _=1,3*fiber_count do -- run fibers, each fiber yields 3 times
    runtime.current_scheduler:run()
end
end_time = sc.monotime()
print("Fiber operation time: "..(end_time - start_time)/(2*3*fiber_count))

assert(count == 3*fiber_count)

print('test: ok')

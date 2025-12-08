--- Tests the Fiber implementation.
print('testing: fibers.fiber')

-- look one level up
package.path = "../src/?.lua;" .. package.path

local runtime = require 'fibers.runtime'
local time = require 'fibers.utils.time'

local function equal(x, y)
    if type(x) ~= type(y) then return false end
    if type(x) == 'table' then
        for k, v in pairs(x) do
            if not equal(v, y[k]) then return false end
        end
        for k, _ in pairs(y) do
            if x[k] == nil then return false end
        end
        return true
    else
        return x == y
    end
end

local log = {}
local function record(x) table.insert(log, x) end

runtime.spawn_raw(function()
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
local start_time = time.monotonic()
local fiber_count = 1e4
local count = 0
local function inc()
    count = count + 1
end
for _=1, fiber_count do
    runtime.spawn_raw(function()
        inc(); runtime.yield(); inc(); runtime.yield(); inc()
    end)
end

local end_time = time.monotonic()
print("Fiber creation time: "..(end_time - start_time)/fiber_count)

start_time = time.monotonic()
for _=1,3*fiber_count do -- run fibers, each fiber yields 3 times
    runtime.current_scheduler:run()
end
end_time = time.monotonic()
print("Fiber operation time: "..(end_time - start_time)/(2*3*fiber_count))

assert(count == 3*fiber_count)

print('test: ok')

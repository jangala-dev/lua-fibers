--- Tests the Cond implementation.
print('testing: fibers.cond')

-- look one level up
package.path = "../src/?.lua;" .. package.path

local cond = require 'fibers.cond'
local runtime = require 'fibers.runtime'
local sleep = require 'fibers.sleep'
local sc = require 'fibers.utils.syscall'

local equal = require 'fibers.utils.helper'.equal

local c, log = cond.new(), {}
local function record(x) table.insert(log, x) end

runtime.spawn_raw(function()
    record('a'); c:wait(); record('b')
end)
runtime.spawn_raw(function()
    record('c'); c:signal(); record('d')
end)
assert(equal(log, {}))
runtime.current_scheduler:run()
assert(equal(log, { 'a', 'c', 'd' }))
runtime.current_scheduler:run()
assert(equal(log, { 'a', 'c', 'd', 'b' }))

runtime.spawn_raw(function()
    local fiber_count = 1e3
    for _ = 1, fiber_count do
        runtime.spawn_raw(function() c:wait(); end)
    end

    sleep.sleep(1)

    local start_time = sc.monotime()
    c:signal()
    local end_time = sc.monotime()

    print("Time taken to signal fiber: ", (end_time - start_time) / fiber_count)
    runtime.stop()
end)

runtime.main()
print('test: ok')

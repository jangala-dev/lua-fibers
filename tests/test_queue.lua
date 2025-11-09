--- Tests the Queue implementation.
print('testing: fibers.queue')

-- look one level up
package.path = "../src/?.lua;" .. package.path

local queue = require 'fibers.queue'
local fiber = require 'fibers.fiber'
local helper = require 'fibers.utils.helper'
local equal = helper.equal

local log = {}
local function record(x) table.insert(log, x) end

fiber.spawn(function()
    local q = queue.new()
    record('a')
    q:put('b')
    record('c')
    q:put('d')
    record('e')
    record(q:get())
    q:put('f')
    record('g')
    record(q:get())
    record('h')
    record(q:get())
end)

local function run(...)
    log = {}
    fiber.current_scheduler:run()
    assert(equal(log, { ... }))
end

-- With the new buffered channel implementation, the behavior is  direct:
run('a', 'c', 'e', 'b', 'g', 'd', 'h', 'f')
for _ = 1, 20 do run() end

print('test: ok')

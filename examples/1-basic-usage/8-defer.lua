-- usage of the fibers.defer functionality showing normal usage

package.path = "../../?.lua;../?.lua;" .. package.path

local fiber = require 'fibers.fiber'
local sleep = require 'fibers.sleep'

local function test_function()
    local defer = fiber.defer()
    
    local a = 1
    defer:add(print, a)
    
    a = 2
    defer:add(print, a)

    a = 3
    defer:add(print, a)

    defer:done()
end

local function main()
    fiber.spawn(test_function)
    sleep.sleep(1)
    print("exiting program")
    fiber.stop()
end

fiber.spawn(main)
fiber.main()
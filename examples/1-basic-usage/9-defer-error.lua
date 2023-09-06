-- usage of the fibers.defer functionality showing cleanup on error

package.path = "../../?.lua;../?.lua;" .. package.path

local fiber = require 'fibers.fiber'
local sleep = require 'fibers.sleep'

local filename_1 = "test1.txt"
local filename_2 = "test2.txt"

local function test_function()
    local defer = fiber.defer()
    
    local file1 = assert(io.open(filename_1, "w"))
    defer:add(file1.close, file1)
    defer:add(print, "Closing file 1")
    
    local file2 = assert(io.open(filename_2, "w"))
    defer:add(file2.close, file2)
    defer:add(print, "Closing file 2")

    error("This is an intentional error!")
    print("We don't get here")
    defer:done()
end

local function main()
    fiber.spawn(test_function)
    sleep.sleep(1)
    assert(os.remove(filename_1))
    assert(os.remove(filename_2))
    print("exiting program")
    fiber.stop()
end

fiber.spawn(main)
fiber.main()
--look for packages one folder up.
package.path = "../../?.lua;../?.lua;" .. package.path

local channel = require 'fibers.channel'
local fiber = require 'fibers.fiber'
local sleep = require 'fibers.sleep'
local go = require 'fibers.go'

local function main()
    local done = channel.new()
    fiber.spawn(function()
        print("Hello")
        sleep.sleep(1)
        print("world")
        sleep.sleep(1)
        print("Foo")
        sleep.sleep(1)
        print("Bar")
        done:put(true)
    end)
    done:get()
end

fiber.spawn(function()
    main()
    fiber.stop()
end)
fiber.main()
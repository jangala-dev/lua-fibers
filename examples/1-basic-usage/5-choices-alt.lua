--- Choice alternative
-- The perform_alt method for a choice operation runs a passed function if
-- none of the operations can be run. This makes the choice non-blocking.
--
-- Example ported from Go's Select https://go.dev/tour/concurrency/6

package.path = "../../?.lua;../?.lua;" .. package.path

local fiber = require 'fibers.fiber'
local channel = require 'fibers.channel'
local sleep = require 'fibers.sleep'
local op = require 'fibers.op'

local perform, choice = require 'fibers.performer'.perform, op.choice

-- time.After() is a Go library function
local function after(t)
    local chan = channel.new()
    fiber.spawn(function()
        sleep.sleep(t)
        chan:put(1)
    end)
    return chan
end

-- time.Tick() is a Go library function
local function tick(t)
    local chan = channel.new()
    fiber.spawn(function()
        while true do
            sleep.sleep(t)
            chan:put(1)
        end
    end)
    return chan
end

fiber.spawn(function()
    local ticker = tick(0.1)
    local boom = after(0.5)
    local done = false
    repeat
        local task = choice(
            ticker:get_op():wrap(function()
                print("tick.")
            end),
            boom:get_op():wrap(function()
                print("BOOM!")
                done = true
            end)
        ):or_else(function()
            print("    .")
            sleep.sleep(0.05)
        end)
        perform(task)
    until done

    fiber.stop()
end)

fiber.main()

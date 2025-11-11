--- Choice alternative
-- The perform_alt method for a choice operation runs a passed function if
-- none of the operations can be run. This makes the choice non-blocking.
--
-- Example ported from Go's Select https://go.dev/tour/concurrency/6

package.path = "../../src/?.lua;../?.lua;" .. package.path

local fibers = require 'fibers'
local channel = require 'fibers.channel'
local sleep = require 'fibers.sleep'

local perform, choice = fibers.perform, fibers.choice

-- time.After() is a Go library function
local function after(t)
    local chan = channel.new()
    fibers.spawn(function()
        sleep.sleep(t)
        chan:put(1)
    end)
    return chan
end

-- time.Tick() is a Go library function
local function tick(t)
    local chan = channel.new()
    fibers.spawn(function()
        while true do
            sleep.sleep(t)
            chan:put(1)
        end
    end)
    return chan
end

local function main()
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
end

fibers.run(main)

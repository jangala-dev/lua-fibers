--- Fibers
-- A fiber is a lightweight thread managed by fibers framework, similar to Go's
-- goroutines. Fibers run in the same address space, so access to shared
-- memory must be synchronised.
--
-- Example ported from Go's Select https://go.dev/tour/concurrency/1

package.path = "../../src/?.lua;../?.lua;" .. package.path

local fibers = require 'fibers'
local sleep = require 'fibers.sleep'

local function say(string)
    for _=1,5 do
        sleep.sleep(0.1)
        print(string)
    end
end

fibers.run(function()
    fibers.spawn(function() say("world") end)
    say("hello")
end)

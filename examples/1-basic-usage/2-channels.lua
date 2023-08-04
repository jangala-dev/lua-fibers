--- Channels
-- Channels are a  conduit through which you can send and receive values.
-- By default, sends and receives block until the other side is ready. 
-- This allows goroutines to synchronize without explicit locks or condition
-- variables. 
--
-- Example ported from Go's Select https://go.dev/tour/concurrency/2


package.path = "../../?.lua;../?.lua;" .. package.path

local fiber = require 'fibers.fiber'
local channel = require 'fibers.channel'

local function sum(array, chan)
    local sum = 0
    for _, j in ipairs(array) do
        sum = sum + j
    end
    chan:put(sum)
end

fiber.spawn(function()
    local s = {7, 2, 8, -9, 4, 0}
    local chan = channel.new()
    fiber.spawn(function() sum({unpack(s,1,#s/2)}, chan) end)
    fiber.spawn(function() sum({unpack(s,#s/2+1,#s)}, chan) end)
    local x, y = chan:get(), chan:get()
    print(x, y, x+y)
    fiber.stop()
end)

fiber.main()
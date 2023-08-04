--- Queue
-- Queues can be thought of as buffered channels. Provide the buffer length
-- as the  argument to new. Puts to a buffered channel block only when the
-- buffer is full. Gets block when the buffer is empty.
--
-- Example ported from Go's Select https://go.dev/tour/concurrency/3


package.path = "../../?.lua;../?.lua;" .. package.path

local fiber = require 'fibers.fiber'
local queue = require 'fibers.queue'

fiber.spawn(function()
    local q = queue.new(2)
    q:put(1)
    q:put(2)
    print(q:get())
    print(q:get())
    fiber.stop()
end)

fiber.main()
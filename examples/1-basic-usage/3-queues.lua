--- Queue
-- Queues can be thought of as buffered channels. Provide the buffer length
-- as the  argument to new. Puts to a buffered channel block only when the
-- buffer is full. Gets block when the buffer is empty.
--
-- Example ported from Go's Select https://go.dev/tour/concurrency/3

package.path = "../../src/?.lua;../?.lua;" .. package.path

local fibers = require 'fibers'
local queue = require 'fibers.queue'

local function main()
    local q = queue.new(2)
    q:put(1)
    q:put(2)
    print(q:get())
    print(q:get())
end

fibers.run(main)

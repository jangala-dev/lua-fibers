-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

--- fibers.queue module
-- Buffered channels for communication between fibers.
-- @module fibers.queue

local channel = require 'fibers.channel'

--- Create a new Queue.
-- @int[opt] bound The upper bound for the number of items in the queue.
-- @treturn Queue The created Queue.
local function new(bound)
    if bound then assert(bound >= 1) end
    return channel.new(bound and bound or math.huge)
end

return {
    new = new
}

-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

--- fibers.queue module
-- Provides Concurrent ML style buffered channels for communication between fibers.
-- @module fibers.queue

local op = require 'fibers.op'
local channel = require 'fibers.channel'
local fiber = require 'fibers.fiber'
local fifo = require 'fibers.utils.fifo'

--- Queue class
-- Represents a queue for communication between fibers.
-- @type Queue
-- local Queue = {}

--- Create a new Queue.
-- @int[opt] bound The upper bound for the number of items in the queue.
-- @treturn Queue The created Queue.
local function new(bound)
    if bound then assert(bound >= 1) end
    local ch_in, ch_out = channel.new(), channel.new()
    local function service_queue()
        local q = fifo.new()
        while true do
            if q:empty() then
                -- Empty.
                q:push(ch_in:get())
            elseif bound and q:length() >= bound then
                -- Full.
                ch_out:put(q:pop())
            else
                local is_put = false
                local getop = ch_in:get_op()
                local putop = ch_out:put_op(q:peek()):wrap(function() is_put = true end)
                local val = op.choice(getop, putop):perform()
                if is_put then
                    -- Put operation succeeded.
                    q:pop()
                else
                    -- Get operation succeeded.
                    q:push(val)
                end
            end
        end
    end
    fiber.spawn(service_queue)
    local ret = {}
    function ret:put_op(x)
        return ch_in:put_op(x)
    end

    function ret:get_op()
        return ch_out:get_op()
    end

    function ret:put(x) self:put_op(x):perform() end

    function ret:get() return self:get_op():perform() end

    return ret
end

return {
    new = new
}

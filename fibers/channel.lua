-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

--- fibers.channel module
-- Provides Concurrent ML style channels for communication between fibers.
-- @module fibers.channel

local op = require 'fibers.op'
local fifo = require 'fibers.utils.fifo'

--- Channel class
-- Represents a communication channel between fibers.
-- @type Channel
local Channel = {}
Channel.__index = Channel

--- Create a new Channel.
-- @treturn Channel The created Channel.
local function new(buffer_size)
    buffer_size = buffer_size or 0 -- Default to unbuffered

    local buffer = nil
    if buffer_size > 0 then
        buffer = fifo.new()
    end

    return setmetatable({
        buffer = buffer,
        buffer_size = buffer_size,
        getq = fifo.new(), -- Queue of waiting receivers
        putq = fifo.new(), -- Queue of waiting senders
    }, Channel)
end

--- Create a put operation for the Channel.
-- Make an operation that if and when it completes will rendezvous with
-- a receiver fiber to send VAL over the channel.
-- @param val The value to put into the Channel.
-- @treturn BaseOp The created put operation.
function Channel:put_op(val)
    local getq, putq, buffer, buffer_size = self.getq, self.putq, self.buffer, self.buffer_size
    local function try()
        -- Case 1: If there's a waiting receiver, complete the rendezvous immediately
        while not getq:empty() do
            local remote = getq:pop()
            if remote.suspension:waiting() then
                remote.suspension:complete(remote.wrap, val)
                return true
            end
            -- Otherwise the remote suspension is already completed, pop and continue
        end
        -- Case 2: If we have a buffer with space, add the value to the buffer
        if buffer and buffer:length() < buffer_size then
            buffer:push(val)
            return true
        end
        -- Case 3: No receivers and no buffer space
        return false
    end
    local function block(suspension, wrap_fn)
        -- First, GC for canceled operations
        while not putq:empty() and not putq:peek().suspension:waiting() do
            putq:pop()
        end
        -- No space in buffer and no receivers, so block
        putq:push({ suspension = suspension, wrap = wrap_fn, val = val })
    end
    return op.new_base_op(nil, try, block)
end

--- Create a get operation for the Channel.
-- Make an operation that if and when it completes will rendezvous with
-- a sender fiber to receive one value from the channel.
-- @treturn BaseOp The created get operation.
function Channel:get_op()
    local getq, putq, buffer = self.getq, self.putq, self.buffer
    local function try()
        -- Case 1: Check if there's a value waiting in the buffer
        if buffer and buffer:length() > 0 then
            return true, buffer:pop()
        end
        -- Case 2: Try to rendezvous with a waiting sender
        while not putq:empty() do
            local remote = putq:pop()
            if remote.suspension:waiting() then
                remote.suspension:complete(remote.wrap)
                return true, remote.val
            end
        end
        -- Case 3: No values available
        return false
    end
    local function block(suspension, wrap_fn)
        -- First, a bit of GC.
        while not getq:empty() and not getq:peek().suspension:waiting() do
            getq:pop()
        end
        -- We have suspended the current fiber; arrange for the fiber to
        -- be resumed by a put operation by adding it to the channel's
        -- getq.
        getq:push({ suspension = suspension, wrap = wrap_fn })
    end
    return op.new_base_op(nil, try, block)
end

--- Put a message into the Channel.
-- Send message on the channel.  If there is already another fiber
-- waiting to receive a message on this channel, give it our message and
-- continue.  Otherwise, block until a receiver becomes available.
-- @tparam any message The message to put into the Channel.
function Channel:put(message)
    self:put_op(message):perform()
end

--- Get a message from the Channel.
-- Receive a message from the channel and return it.  If there is
-- already another fiber waiting to send a message on this channel, take
-- its message directly.  Otherwise, block until a sender becomes
-- available.
-- @treturn any The message retrieved from the Channel.
function Channel:get()
    return self:get_op():perform()
end

--- @export
return {
    new = new
}

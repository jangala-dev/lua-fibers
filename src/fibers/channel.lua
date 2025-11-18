-- fibers.channel
-- Provides Concurrent ML style channels for communication between fibers.

local op      = require 'fibers.op'
local fifo    = require 'fibers.utils.fifo'
local perform = require 'fibers.performer'.perform

local Channel = {}
Channel.__index = Channel

local function new(buffer_size)
    buffer_size = buffer_size or 0

    local buffer = nil
    if buffer_size > 0 then
        buffer = fifo.new()
    end

    return setmetatable({
        buffer      = buffer,
        buffer_size = buffer_size,
        getq        = fifo.new(), -- waiting receivers
        putq        = fifo.new(), -- waiting senders
    }, Channel)
end

----------------------------------------------------------------------
-- Helpers: pop active entries based on suspension state
----------------------------------------------------------------------

local function pop_active(q)
    while not q:empty() do
        local entry = q:pop()
        if not entry.suspension or entry.suspension:waiting() then
            return entry
        end
    end
    return nil
end

----------------------------------------------------------------------
-- PUT side
----------------------------------------------------------------------

function Channel:put_op(val)
    local getq, putq = self.getq, self.putq
    local buffer, buffer_size = self.buffer, self.buffer_size

    -- Per-operation state for this event instance.
    local entry = {
        val        = val,
        suspension = nil,
        wrap       = nil,
    }

    local function try()
        -- Case 1: rendezvous with a waiting receiver.
        local recv = pop_active(getq)
        if recv then
            recv.suspension:complete(recv.wrap, val)
            return true
        end
        -- Case 2: buffered channel with available space.
        if buffer and buffer:length() < buffer_size then
            buffer:push(val)
            return true
        end
        -- Case 3: no receiver and no buffer space.
        return false
    end

    local function block(suspension, wrap_fn)
        entry.suspension = suspension
        entry.wrap       = wrap_fn
        putq:push(entry)
    end

    return op.new_primitive(nil, try, block)
end

----------------------------------------------------------------------
-- GET side
----------------------------------------------------------------------

function Channel:get_op()
    local getq, putq = self.getq, self.putq
    local buffer     = self.buffer

    local entry = {
        suspension = nil,
        wrap       = nil,
    }

    local function pop_sender()
        local sender = pop_active(putq)
        if not sender then
            return nil
        end
        -- Having chosen this sender, complete its suspension immediately.
        sender.suspension:complete(sender.wrap)
        return sender
    end

    local function try()
        local remote = pop_sender()
        -- Case 1: take from buffer if there is a buffered value.
        if buffer and buffer:length() > 0 then
            local v = buffer:pop()
            -- If there was a sender waiting, refill the buffer with its value.
            if remote then
                buffer:push(remote.val)
            end
            return true, v
        end
        -- Case 2: no buffered value; take directly from a sender.
        if remote then
            return true, remote.val
        end
        -- Case 3: nothing available.
        return false
    end

    local function block(suspension, wrap_fn)
        entry.suspension = suspension
        entry.wrap       = wrap_fn
        getq:push(entry)
    end

    return op.new_primitive(nil, try, block)
end

----------------------------------------------------------------------
-- Synchronous wrappers
----------------------------------------------------------------------

function Channel:put(message)
    return perform(self:put_op(message))
end

function Channel:get()
    return perform(self:get_op())
end

return {
    new = new,
}

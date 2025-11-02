-- fibers/channel.lua
local scope_mod = require 'fibers.scope'
local op        = require 'fibers.op'
local fifo      = require 'fibers.utils.fifo'

local Channel = {}
Channel.__index = Channel

local function new(buffer_size)
    buffer_size = buffer_size or 0
    return setmetatable({
        buffer      = buffer_size > 0 and fifo.new() or nil,
        buffer_size = buffer_size,
        getq        = fifo.new(), -- receivers: nodes {susp=<Suspension>}
        putq        = fifo.new(), -- senders:   nodes {susp=<Suspension>, val=<any>}
    }, Channel)
end

local function pop_live(q)
    while not q:empty() do
        local n = q:pop()
        if not n.removed and n.susp and n.susp:waiting() then return n end
    end
end
function Channel:put_op(val)
    local getq, putq, buffer, buffer_size = self.getq, self.putq, self.buffer, self.buffer_size

    local function try()
        local rx = pop_live(getq)
        if rx then
            rx.susp:complete(val)
            return true
        end
        if buffer and buffer:length() < buffer_size then
            buffer:push(val)
            return true
        end
        return false
    end

    local function install(ctx, susp)
        local node = { susp = susp, val = val }
        putq:push(node)
        ctx.defer_loser(function() node.removed = true end) -- O(1)
        -- no commit hook needed; receiver completes us
    end

    return op.new(nil, try, install)
end

function Channel:get_op()
    local getq, putq, buffer = self.getq, self.putq, self.buffer

    local function try()
        if buffer and buffer:length() > 0 then
            local v = buffer:pop()
            local tx = pop_live(putq)
            if tx then
                buffer:push(tx.val); tx.susp:complete()
            end
            return true, v
        end
        local tx = pop_live(putq)
        if tx then
            tx.susp:complete()
            return true, tx.val
        end
        return false
    end

    local function install(ctx, susp)
        local node = { susp = susp }
        getq:push(node)
        ctx.defer_loser(function() node.removed = true end) -- O(1)
    end

    return op.new(nil, try, install)
end

function Channel:get(scope)
    scope = scope or scope_mod.current()
    if not scope then return false, "no-scope" end
    local ok, v_or_cause = scope:wait(self:get_op())
    return ok, v_or_cause
end

function Channel:put(val, scope)
    scope = scope or scope_mod.current()
    if not scope then return false, "no-scope" end
    local ok, cause = scope:wait(self:put_op(val))
    -- successful puts have no value payload
    return ok, ok and nil or cause
end
-- Optional convenience methods using a current scope when present can be added later.
return {
    new = new
}

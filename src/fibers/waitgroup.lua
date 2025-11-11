-- fibers/waitgroup.lua
local op      = require 'fibers.op'
local perform = require 'fibers.performer'.perform

local Waitgroup = {}
Waitgroup.__index = Waitgroup

local function new()
    return setmetatable({
        _counter = 0,
        _cond    = nil,   -- per-generation condition; nil when idle
    }, Waitgroup)
end

function Waitgroup:add(delta)
    if delta == 0 then
        return
    end

    local old_waiters = self._counter
    local new_waiters = old_waiters + delta

    if new_waiters < 0 then
        error("waitgroup counter goes negative")
    end

    self._counter = new_waiters

    if new_waiters == 0 then
        -- This generation completes: wake any waiters.
        if self._cond then
            self._cond.signal()
        end
        -- _cond remains a triggered cond for this generation; a new
        -- generation will allocate a fresh cond when counter rises from 0.
    elseif old_waiters == 0 and new_waiters > 0 then
        -- Starting a new generation: new condition for new work.
        self._cond = op.new_cond()
    end
end

function Waitgroup:done()
    self:add(-1)
end

function Waitgroup:wait_op()
    local function try()
        return self._counter == 0
    end

    local function block(suspension, wrap_fn)
        -- Re-check after try(): counter may have become zero meanwhile.
        if self._counter == 0 then
            suspension:complete(wrap_fn)
            return
        end

        -- At this point we are in an active generation.
        local cond = self._cond
        if not cond then
            error("waitgroup internal error: missing condition for active generation")
        end

        local cond_op = cond.wait_op()
        cond_op.block_fn(suspension, wrap_fn)
    end

    return op.new_primitive(nil, try, block)
end

function Waitgroup:wait()
    return perform(self:wait_op())
end

return {
    new = new,
}

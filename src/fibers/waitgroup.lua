-- fibers/waitgroup.lua
local op          = require 'fibers.op'
local perform     = require 'fibers.performer'.perform
local cond_mod    = require 'fibers.cond'

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

    local old_count = self._counter
    local new_count = old_count + delta

    if new_count < 0 then
        error("waitgroup counter goes negative")
    end

    self._counter = new_count

    if new_count == 0 then
        -- This generation completes: wake any waiters and drop the cond.
        if self._cond then
            self._cond:signal()
            self._cond = nil
        end
    elseif old_count == 0 and new_count > 0 then
        -- Starting a new generation: new condition for new work.
        self._cond = cond_mod.new()
    end
end

function Waitgroup:done()
    self:add(-1)
end

function Waitgroup:wait_op()
    -- Build the event lazily at sync time.
    return op.guard(function()
        -- If there is nothing outstanding, fire immediately.
        if self._counter == 0 then
            return op.always()
        end

        -- Active generation: delegate to the generation's condition.
        local cond = assert(self._cond, "waitgroup internal error: missing condition for active generation")

        return cond:wait_op()
    end)
end

function Waitgroup:wait()
    return perform(self:wait_op())
end

return {
    new = new,
}

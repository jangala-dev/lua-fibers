-- waitgroup.lua
local op = require 'fibers.op'

local perform = require 'fibers.performer'.perform

local Waitgroup = {}
Waitgroup.__index = Waitgroup

local function new()
    -- Use the core condition primitive directly: { wait_op = ..., signal = ... }
    local wg = setmetatable({
        _counter = 0,
        _cond    = op.new_cond(),
    }, Waitgroup)
    return wg
end

function Waitgroup:add(count)
    self._counter = self._counter + count
    if self._counter < 0 then
        error("waitgroup counter goes negative")
    elseif self._counter == 0 then
        self._cond.signal()
    end
end

function Waitgroup:done()
    self:add(-1)
end

function Waitgroup:wait_op()
    -- Take the underlying cond's wait op (a BaseOp).
    local cond_op = self._cond.wait_op()
    local function try()
        return self._counter == 0
    end

    local function block(suspension, wrap_fn)
        if self._counter == 0 then
            -- Became zero after try() but before block() ran.
            suspension:complete(wrap_fn)
        else
            -- Delegate blocking to the underlying condition's block_fn.
            cond_op.block_fn(suspension, wrap_fn)
        end
    end

    return op.new_primitive(nil, try, block)
end

function Waitgroup:wait()
    return perform(self:wait_op())
end

return {
    new = new
}

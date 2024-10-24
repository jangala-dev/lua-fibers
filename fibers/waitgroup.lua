-- waitgroup.lua
local op = require 'fibers.op'
local cond = require 'fibers.cond'

local Waitgroup = {}
Waitgroup.__index = Waitgroup

local function new()
    local wg = setmetatable({ _counter = 0, _cond = cond.new() }, Waitgroup)
    return wg
end

function Waitgroup:add(count)
    self._counter = self._counter + count
    if self._counter < 0 then
        error("waitgroup counter goes negative")
    elseif self._counter == 0 then
        self._cond:signal()
    end
end

function Waitgroup:done()
    self:add(-1)
end

-- Override a conditional wait operation to make a waitgroup operation
-- @return BaseOp a base op for a waitgroup
function Waitgroup:wait_op()
    local wait_op = self._cond:wait_op()
    wait_op.try_fn = function() return self._counter <= 0 end
    return wait_op
end

function Waitgroup:wait()
    self:wait_op():perform()
end

return {
    new = new
}

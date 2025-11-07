--- fibers.cond module.
-- Thin wrapper around the core condition primitive in fibers.op.
-- A Cond is a one-shot, signal-all rendezvous: once signalled,
-- all current and future waiters complete.
-- @module fibers.cond

local op = require 'fibers.op'

local perform = op.perform

local Cond = {}
Cond.__index = Cond

--- Create a new condition variable.
-- @treturn Cond The new condition variable.
local function new()
    -- op.new_cond() returns a table with wait_op() and signal().
    local prim = op.new_cond()
    return setmetatable(prim, Cond)
end

--- Operation that waits on the condition.
-- This is provided by op.new_cond() as prim.wait_op.
-- @treturn operation The created operation.
-- function Cond:wait_op() ... end  -- inherited from prim

--- Put the fiber into a wait state on the condition variable.
function Cond:wait()
    return perform(self:wait_op())
end

--- Wake up all fibers that are waiting on this condition variable.
-- This is provided by op.new_cond() as prim.signal().
-- function Cond:signal() ... end  -- inherited from prim

return {
    new = new
}

--- fibers/cond.lua
---
-- Generic condition events built on top of oneshot and op.
--
-- A cond has:
--   cond:wait_op() -> Event
--   cond:wait()    -- blocking, via performer
--   cond:signal()  -- idempotent

local op        = require 'fibers.op'
local oneshot   = require 'fibers.oneshot'
local perform   = require 'fibers.performer'.perform

local Cond = {}
Cond.__index = Cond

function Cond:wait_op()
    local os = self._os

    return op.new_primitive(
        nil,
        function()
            return os:is_triggered()
        end,
        function(resumer, wrap_fn)
            -- Arrange to complete this suspension when the condition fires.
            os:add_waiter(function()
                if resumer:waiting() then
                    resumer:complete(wrap_fn)
                end
            end)
        end
    )
end

function Cond:wait()
    return perform(self:wait_op())
end

function Cond:signal()
    return self._os:signal()
end

local function new()
    return setmetatable({
        _os = oneshot.new(),  -- no extra callback
    }, Cond)
end

return {
    new = new,
}

-- fibers/cond.lua
---
-- Generic condition events built on top of signaller and op.
--
-- A cond has:
--   cond.wait_op() -> Event
--   cond.signal()  -- idempotent

local op        = require 'fibers.op'
local signaller = require 'fibers.signaller'
local perform   = require 'fibers.performer'.perform

local Cond = {}
Cond.__index = Cond

function Cond:wait_op()
    return op.new_primitive(
        nil,
        function() return self.sig.triggered end,
        function(resumer, wrap_fn) self.sig:add_waiter(resumer, wrap_fn) end
    )
end

function Cond:wait()
    return perform(self:wait_op())
end

function Cond:signal()
    return self.sig:signal()
end

local function new()
    return setmetatable({
        sig = signaller.new(),
    }, Cond)
end

return {
    new = new,
}

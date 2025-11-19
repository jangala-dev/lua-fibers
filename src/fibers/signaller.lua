-- fibers/signaller.lua

local Signaller   = {}
Signaller.__index = Signaller

local function new()
    return setmetatable({
        triggered = false,
        waiters   = {},  -- array of { resumer = ..., wrap = ... }
    }, Signaller)
end

function Signaller:add_waiter(resumer, wrap_fn)
    if self.triggered then
        if resumer:waiting() then
            resumer:complete(wrap_fn)
        end
        return
    end

    local waiters = self.waiters
    waiters[#waiters + 1] = {
        resumer = resumer,
        wrap    = wrap_fn,
    }
end

function Signaller:signal()
    if self.triggered then return end
    self.triggered = true

    local waiters = self.waiters
    for i = 1, #waiters do
        local w = waiters[i]
        waiters[i] = nil
        if w
           and w.resumer
           and w.resumer:waiting()
        then
            w.resumer:complete(w.wrap)
        end
    end
end

return {
    new       = new,
    Signaller = Signaller,
}

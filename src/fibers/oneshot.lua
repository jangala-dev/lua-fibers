-- fibers/oneshot.lua

local OneShot = {}
OneShot.__index = OneShot

local function new(on_after_signal)
    return setmetatable({
        triggered       = false,
        waiters         = {},             -- array of functions()
        on_after_signal = on_after_signal -- optional
    }, OneShot)
end

function OneShot:add_waiter(thunk)
    if self.triggered then
        -- Already triggered: run immediately.
        thunk()
        return
    end

    local ws = self.waiters
    ws[#ws + 1] = thunk
end

function OneShot:signal()
    if self.triggered then return end
    self.triggered = true

    local ws = self.waiters
    for i = 1, #ws do
        local f = ws[i]
        ws[i] = nil
        if f then f() end
    end

    local cb = self.on_after_signal
    if cb then
        cb()
    end
end

function OneShot:is_triggered()
    return self.triggered
end

return {
    new = new,
}

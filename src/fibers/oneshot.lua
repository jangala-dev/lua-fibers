-- fibers/oneshot.lua

--- One-shot notification primitive.
---@module 'fibers.oneshot'

---@alias OneshotWaiter fun()

---@class Oneshot
---@field triggered boolean
---@field waiters OneshotWaiter[]
---@field on_after_signal fun()|nil
local Oneshot = {}
Oneshot.__index = Oneshot

--- Create a new one-shot.
---@param on_after_signal? fun() # optional callback run after signalling all waiters
---@return Oneshot
local function new(on_after_signal)
	return setmetatable({
		triggered       = false,
		waiters         = {},
		on_after_signal = on_after_signal,
	}, Oneshot)
end

--- Register a waiter.
--- If already triggered, the thunk is run immediately.
---@param thunk OneshotWaiter
function Oneshot:add_waiter(thunk)
	if self.triggered then
		thunk()
		return
	end

	local ws = self.waiters
	ws[#ws + 1] = thunk
end

--- Trigger the one-shot.
--- All waiters are run once; the optional callback runs afterwards.
--- Idempotent: subsequent calls after the first have no effect.
function Oneshot:signal()
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

--- Check whether the one-shot has fired.
---@return boolean
function Oneshot:is_triggered()
	return self.triggered
end

return {
	new = new,
}

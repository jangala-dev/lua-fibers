-- fibers/pulse2.lua
--
-- Unified waitable primitive:
--   * Source pulse: Pulse.new(sched) supports :signal(), :signal_if_waiting(), :subscribe(token, epoch)
--   * Derived waitable: Pulse.any(...) / Pulse.any_from_array(arr, n) supports :subscribe(token, epoch)
--
-- Correctness points:
--   * Waiter entries store (token, epoch) pairs so stale subscriptions cannot wake later waits.
--   * Unsubscribe validates (token, epoch) at the recorded index; otherwise it is a no-op.
--   * Swap-with-tail removal updates moved token handle indices via token:_moved(...), required.

local Pulse = {}
Pulse.__index = Pulse

----------------------------------------------------------------------
-- Constructors
----------------------------------------------------------------------

function Pulse.new(sched)
	return setmetatable({
		kind  = 'src',
		sched = sched,
		ws    = {},  -- pairs: ws[2*i-1]=token, ws[2*i]=epoch
		nwait = 0,   -- number of waiter pairs
	}, Pulse)
end

local function flatten_any(out, x)
	if type(x) ~= 'table' or getmetatable(x) ~= Pulse then
		error('Pulse.any expects Pulse values', 3)
	end
	if x.kind == 'any' then
		local xs = x.srcs
		for i = 1, #xs do out[#out + 1] = xs[i] end
	else
		out[#out + 1] = x
	end
end

function Pulse.any(...)
	local args = { ... }
	if #args == 0 then error('Pulse.any expects at least one Pulse', 2) end

	local srcs = {}
	for i = 1, #args do
		flatten_any(srcs, args[i])
	end

	return setmetatable({ kind = 'any', srcs = srcs }, Pulse)
end

-- Avoid unpack/varargs from composites that already have a scratch array.
function Pulse.any_from_array(arr, n)
	if n == 0 then error('Pulse.any_from_array expects n>0', 2) end
	if n == 1 then return arr[1] end

	local srcs = {}
	for i = 1, n do
		flatten_any(srcs, arr[i])
	end
	return setmetatable({ kind = 'any', srcs = srcs }, Pulse)
end

----------------------------------------------------------------------
-- Source pulse internals
----------------------------------------------------------------------

function Pulse:_subscribe_token(token, epoch)
	local n = self.nwait + 1
	self.nwait = n

	local j = (n - 1) * 2 + 1
	local ws = self.ws
	ws[j]     = token
	ws[j + 1] = epoch

	return n -- waiter index (pair index)
end

function Pulse:_unsubscribe_at(idx, token, epoch)
	local n = self.nwait
	if idx < 1 or idx > n then return end

	local ws = self.ws
	local j  = (idx - 1) * 2 + 1

	-- Validate that the entry is still this (token, epoch).
	if ws[j] ~= token or ws[j + 1] ~= epoch then
		return
	end

	-- Swap-with-tail removal.
	local tj = (n - 1) * 2 + 1
	local moved_tok   = ws[tj]
	local moved_epoch = ws[tj + 1]

	ws[tj], ws[tj + 1] = nil, nil
	self.nwait = n - 1

	if idx ~= n then
		ws[j], ws[j + 1] = moved_tok, moved_epoch
		-- Update the moved token's handle index for this pulse/epoch.
		-- This is required for correctness.
		moved_tok:_moved(self, n, idx, moved_epoch)
	end
end

----------------------------------------------------------------------
-- Waitable interface
----------------------------------------------------------------------

function Pulse:has_waiters()
	return self.kind == 'src' and self.nwait ~= 0
end

function Pulse:signal_if_waiting()
	if self.kind ~= 'src' then
		error('signal_if_waiting: not a source pulse', 2)
	end
	if self.nwait == 0 then return end
	return self:signal()
end

function Pulse:subscribe(token, epoch)
	if self.kind == 'src' then
		local idx = self:_subscribe_token(token, epoch)
		token:_add_handle(self, idx, epoch)
		return
	end

	-- kind == 'any': subscribe to each source, de-duped per token+epoch.
	local srcs = self.srcs
	for i = 1, #srcs do
		local s = srcs[i]
		if not token:_subscribed_to(s, epoch) then
			local idx = s:_subscribe_token(token, epoch)
			token:_add_handle(s, idx, epoch)
		end
	end
end

function Pulse:signal()
	if self.kind ~= 'src' then
		error('signal: cannot signal a derived waitable', 2)
	end

	local n = self.nwait
	if n == 0 then return end

	local ws    = self.ws
	local sched = self.sched

	-- Clear the waiter set up front.
	self.nwait = 0

	for i = 1, n do
		local j = (i - 1) * 2 + 1
		local tok   = ws[j]
		local epoch = ws[j + 1]
		ws[j], ws[j + 1] = nil, nil

		-- Best-effort: ignore nil tokens (should not happen).
		if tok then
			tok:_woken_by(self, sched, epoch)
		end
	end
end

return {
	Pulse          = Pulse,
	new            = Pulse.new,
	any            = Pulse.any,
	any_from_array = Pulse.any_from_array,
}

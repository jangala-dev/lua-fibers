-- fibers/pulse2.lua
--
-- Pulse: the sole wait/wake primitive for fibres, plus an "any" waitable view.
--
-- Purpose
--   A Pulse represents a point of synchronisation. Fibres block by subscribing a
--   wait token to a waitable and yielding; they wake only when a pulse signals.
--
-- Source Pulse contract
--   * Pulse.new(sched) creates a source pulse bound to a scheduler.
--   * pulse:subscribe(token, epoch) registers (token, epoch) as a waiter.
--   * pulse:signal() schedules all currently-subscribed tokens (best-effort).
--   * pulse:signal_if_waiting() is an optimisation (no-op if no live waiters).
--   * pulse:_unsubscribe_at(idx, token, epoch) tombstones a waiter entry.
--
-- Correctness model
--   * Waiters are stored as (token, epoch) pairs.
--   * Unsubscribe validates (token, epoch) at the recorded index; otherwise it is a no-op.
--   * signal() drains the entire waiter set; tombstones are ignored.
--   * This module does not reschedule fibres directly: it calls token:_woken_by(...),
--     which validates the epoch and performs cancellation before scheduling the fibre.
--
-- Any waitable view
--   * Any.new() returns a reusable view object: any:set(arr, n)
--   * any:subscribe(token, epoch) subscribes the token to each pulse in arr[1..n]
--   * This is a view (no per-await allocation/flattening); it assumes callers manage arr.
--
-- API
--   * Pulse.new(sched) -> pulse
--   * Any.new() -> any_view

local Pulse = {}
Pulse.__index = Pulse

function Pulse.new(sched)
	return setmetatable({
		sched  = sched,
		ws     = {}, -- pairs
		n      = 0,
		live   = 0,
		free   = {}, -- stack of reusable slot indices
		free_n = 0,
	}, Pulse)
end

function Pulse:has_waiters()
	return self.live ~= 0
end

function Pulse:signal_if_waiting()
	if self.live == 0 then return end
	return self:signal()
end

function Pulse:subscribe(token, epoch)
	local idx

	-- Reuse a tombstoned slot if available.
	local fn = self.free_n
	if fn ~= 0 then
		idx = self.free[fn]
		self.free[fn] = nil
		self.free_n = fn - 1
	else
		idx = self.n + 1
		self.n = idx
	end

	self.live = self.live + 1

	local ws  = self.ws
	local j   = (idx - 1) * 2 + 1
	ws[j]     = token
	ws[j + 1] = epoch

	token:_add_handle(self, idx, epoch)
end

function Pulse:_unsubscribe_at(idx, token, epoch)
	if idx < 1 or idx > self.n then return false end

	local ws = self.ws
	local j  = (idx - 1) * 2 + 1
	if ws[j] ~= token or ws[j + 1] ~= epoch then
		return false
	end

	-- Tombstone (no index movement).
	ws[j]     = false
	ws[j + 1] = 0
	self.live = self.live - 1

	-- Make the slot reusable.
	local fn = self.free_n + 1
	self.free_n = fn
	self.free[fn] = idx

	return true
end

function Pulse:signal()
	local n = self.n
	if n == 0 then return end

	local ws    = self.ws
	local sched = self.sched

	-- Reset counters and clear free list (old indices are meaningless after reset).
	self.n = 0
	self.live = 0
	for i = 1, self.free_n do self.free[i] = nil end
	self.free_n = 0

	for i = 1, n do
		local j          = (i - 1) * 2 + 1
		local tok        = ws[j]
		local ep         = ws[j + 1]
		ws[j], ws[j + 1] = nil, nil

		if tok and tok ~= false then
			tok:_woken_by(self, sched, ep)
		end
	end
end

----------------------------------------------------------------------
-- Any waitable view (no allocation per await)
----------------------------------------------------------------------

local Any = {}
Any.__index = Any

function Any.new()
	return setmetatable({ arr = nil, n = 0 }, Any)
end

function Any:set(arr, n)
	self.arr = arr
	self.n   = n
	return self
end

function Any:subscribe(token, epoch)
	local arr = self.arr
	for i = 1, self.n do
		arr[i]:subscribe(token, epoch)
	end
end

return {
	Pulse    = Pulse,
	new      = Pulse.new,
	Any      = Any,
	any_view = Any.new, -- convenience
}

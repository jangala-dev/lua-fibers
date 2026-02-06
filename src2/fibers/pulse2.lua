local Pulse = {}
Pulse.__index = Pulse

-- Representation:
--   ws holds pairs per slot:
--     ws[(idx-1)*2+1]   = fib | false   (false means “tombstoned/free”)
--     ws[(idx-1)*2+2]   = epoch | next_free_idx
--   free_head is the head of a singly-linked free list of slot indices.
--
-- When a slot is freed, we set ws[j] = false and ws[j+1] = free_head, then free_head = idx.

function Pulse.new(sched)
	return setmetatable({
		sched     = sched,
		ws        = {},  -- pairs: [fib|false, epoch|next_free]
		n         = 0,
		live      = 0,
		free_head = 0,   -- 0 means “no free slots”
	}, Pulse)
end

function Pulse:has_waiters()
	return self.live ~= 0
end

function Pulse:signal_if_waiting()
	if self.live == 0 then return end
	return self:signal()
end

-- Subscribe a fibre for a given epoch.
-- Allocation-free: stores (fib, epoch) into ws, and gives (pulse, idx) handle to fibre.
function Pulse:subscribe_fibre(fib, epoch)
	local idx = self.free_head
	if idx ~= 0 then
		-- Pop from free list.
		local j = (idx - 1) * 2 + 1
		self.free_head = self.ws[j + 1] or 0
	else
		-- Grow.
		idx = self.n + 1
		self.n = idx
	end

	self.live = self.live + 1

	local ws = self.ws
	local j  = (idx - 1) * 2 + 1
	ws[j]     = fib
	ws[j + 1] = epoch

	fib:_add_handle(self, idx)
end

function Pulse:_unsubscribe_at(idx, fib, epoch)
	if idx < 1 or idx > self.n then return false end

	local ws = self.ws
	local j  = (idx - 1) * 2 + 1
	if ws[j] ~= fib or ws[j + 1] ~= epoch then
		return false
	end

	-- Tombstone and push onto free list.
	ws[j]     = false
	ws[j + 1] = self.free_head
	self.free_head = idx

	self.live = self.live - 1
	return true
end

function Pulse:signal()
	local n = self.n
	if n == 0 then return end

	local ws    = self.ws
	local sched = self.sched

	-- Reset counters (existing indices become meaningless after this).
	self.n         = 0
	self.live      = 0
	self.free_head = 0

	for i = 1, n do
		local j          = (i - 1) * 2 + 1
		local fib        = ws[j]
		local ep         = ws[j + 1]
		ws[j], ws[j + 1] = nil, nil

		if fib and fib ~= false then
			fib:_woken_by(self, sched, ep)
		end
	end
end

return {
	Pulse = Pulse,
	new   = Pulse.new,
}

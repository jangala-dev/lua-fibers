-- fibers/channel2.lua
--
-- Unbuffered rendezvous channel expressed as preview/commit ops with precise wakeups.
-- Offerless protocol: commit() and abort() take no arguments.
--
-- This revision eliminates redundant signalling:
--   * push_put/push_get return whether they inserted; we signal only on insertion.
--   * detach_uncommitted returns whether it changed state; callers signal once per call.
--   * GetOp:preview and GetOp:abort collapse multiple possible wake causes into one signal.

local runtime   = require 'fibers.runtime2'
local pulse_mod = require 'fibers.pulse2'
local op        = require 'fibers.op2'

local EMPTY = op.EMPTY

----------------------------------------------------------------------
-- Intrusive queues: put list and get list
----------------------------------------------------------------------

local function unlink_put(ch, n)
	if not n.inq then return end
	local prev, next = n.prev, n.next
	if prev then prev.next = next else ch.put_h = next end
	if next then next.prev = prev else ch.put_t = prev end
	n.prev, n.next = nil, nil
	n.inq = false
end

local function unlink_get(ch, n)
	if not n.inq then return end
	local prev, next = n.prev, n.next
	if prev then prev.next = next else ch.get_h = next end
	if next then next.prev = prev else ch.get_t = prev end
	n.prev, n.next = nil, nil
	n.inq = false
end

-- Return true if the node was inserted (state changed), false if already enqueued.
local function push_put(ch, n)
	if n.inq then return false end
	n.prev = ch.put_t
	n.next = nil
	n.inq  = true
	if ch.put_t then ch.put_t.next = n else ch.put_h = n end
	ch.put_t = n
	return true
end

-- Return true if the node was inserted (state changed), false if already enqueued.
local function push_get(ch, n)
	if n.inq then return false end
	n.prev = ch.get_t
	n.next = nil
	n.inq  = true
	if ch.get_t then ch.get_t.next = n else ch.get_h = n end
	ch.get_t = n
	return true
end

local function find_unmatched_put(head)
	local n = head
	while n do
		if (not n.done) and (n.peer == nil) then
			return n
		end
		n = n.next
	end
	return nil
end

local function find_eligible_get(head)
	local n = head
	while n do
		if (not n.done) and (n.peer == nil) then
			local sel = n._sel
			if not sel then
				return n
			end
			local w = sel.winner
			if (w == nil) or (w == n) then
				return n
			end
		end
		n = n.next
	end
	return nil
end

----------------------------------------------------------------------
-- Channel
----------------------------------------------------------------------

local Channel = {}
Channel.__index = Channel

function Channel.new()
	local sched = runtime.scheduler()
	return setmetatable({
		pulse = pulse_mod.new(sched),
		put_h = nil, put_t = nil,
		get_h = nil, get_t = nil,
	}, Channel)
end

local function signal(ch)
	ch.pulse:signal_if_waiting()
end

local function pending_preview(ch)
	return ch.pulse, nil, nil
end

----------------------------------------------------------------------
-- Reservation/commit helpers
----------------------------------------------------------------------

local function bump(x)
	x.key = x.key + 1
end

-- Detach a peer pairing if present. Returns true if it changed state.
local function detach_uncommitted(a, b)
	local changed = false
	if a.peer == b then
		a.peer = nil
		bump(a)
		changed = true
	end
	if b.peer == a then
		b.peer = nil
		bump(b)
		changed = true
	end
	return changed
end

local function commit_pair(ch, putop, getop)
	if putop.done then return end

	putop.done   = true
	getop.done   = true
	getop.result = putop.val

	-- Keys change on commit to reflect a new stable state.
	bump(putop)
	bump(getop)

	unlink_put(ch, putop)
	unlink_get(ch, getop)

	putop.peer = nil
	getop.peer = nil

	-- This commit may unblock waiters.
	signal(ch)
end

----------------------------------------------------------------------
-- PUT op
----------------------------------------------------------------------

local PutOp = {}
PutOp.__index = PutOp
setmetatable(PutOp, { __index = op.Op })

function Channel:put_op(val)
	return setmetatable({
		ch    = self,
		val   = val,
		peer  = nil,
		done  = false,

		key   = 0, -- opaque readiness/signature key

		prev  = nil,
		next  = nil,
		inq   = false,
	}, PutOp)
end

function PutOp:watch()
	if self.done then return nil end
	return self.ch.pulse
end

function PutOp:preview()
	local ch = self.ch

	if self.done then
		return nil, self.key, EMPTY
	end

	local g = self.peer
	if g then
		local sel = g._sel
		if sel and sel.winner ~= g then
			return pending_preview(ch)
		end
		return nil, self.key, EMPTY
	end

	local r = find_eligible_get(ch.get_h)
	if r then
		self.peer = r
		r.peer    = self

		-- Reservation changes readiness signatures.
		bump(self)
		bump(r)

		-- NEW: stop scanning paired nodes.
		-- Once paired (peer set), neither side is eligible to be matched again,
		-- so remove them from the wait-queues immediately. This keeps
		-- find_eligible_get/find_unmatched_put scans short under load.
		--
		-- (unlink_* are idempotent: safe even if not enqueued.)
		if self.inq then
			unlink_put(ch, self)
		end
		if r.inq then
			unlink_get(ch, r)
		end

		-- Reservation can unblock waiters.
		signal(ch)

		local sel = r._sel
		if sel and sel.winner == nil then
			-- Sender not ready until receiver claims arbitration.
			return pending_preview(ch)
		end

		return nil, self.key, EMPTY
	end

	-- Not ready: enqueue and wait. Only signal if we actually inserted.
	if push_put(ch, self) then
		signal(ch)
	end
	return pending_preview(ch)
end

-- Offerless commit: relies on reservation state created by the last ready preview().
function PutOp:commit()
	if self.done then
		return EMPTY
	end

	local g = self.peer
	if not g then
		error('channel.put.commit: commit without a ready preview (no peer)', 0)
	end

	local sel = g._sel
	if sel and sel.winner ~= g then
		error('channel.put.commit: commit without a ready preview (lost arbitration)', 0)
	end

	commit_pair(self.ch, self, g)
	return EMPTY
end

function PutOp:abort()
	if self.done then return end

	local ch = self.ch
	local changed = false

	local g = self.peer
	if g and (not g.done) then
		if detach_uncommitted(self, g) then
			changed = true
		end
	end

	unlink_put(ch, self)
	self.peer = nil

	-- Signal once if we changed pairing state.
	if changed then
		signal(ch)
	end
end

----------------------------------------------------------------------
-- GET op
----------------------------------------------------------------------

local GetOp = {}
GetOp.__index = GetOp
setmetatable(GetOp, { __index = op.Op })

function Channel:get_op()
	return setmetatable({
		ch     = self,
		peer   = nil,
		result = nil,
		done   = false,

		key    = 0,

		_sel = nil,
		prev = nil,
		next = nil,
		inq  = false,

		-- payload-as-self (avoids alloc)
		n = 0,
	}, GetOp)
end

function GetOp:_attach_select(sel)
	self._sel = sel
end

function GetOp:watch()
	if self.done then return nil end
	return self.ch.pulse
end

local function payload_set(self, v)
	self.n = 1
	self[1] = v
	return self
end

local function payload_clear(self)
	self.n = 0
	self[1] = nil
end

function GetOp:preview()
	local ch  = self.ch
	local sel = self._sel

	if self.done then
		self.n = 1
		self[1] = self.result
		return nil, self.key, self
	end

	-- Known loser in a choice: do not participate; wait on channel.
	if sel and sel.winner and sel.winner ~= self then
		return pending_preview(ch)
	end

	local p = self.peer
	if p then
		-- Claim winner on first readiness.
		if sel and sel.winner == nil then
			sel.winner = self
			signal(ch)
		end

		if sel and sel.winner ~= self then
			return pending_preview(ch)
		end

		self.n = 1
		self[1] = p.val
		return nil, self.key, self
	end

	local s = find_unmatched_put(ch.put_h)
	if s then
		self.peer = s
		s.peer    = self

		bump(self)
		bump(s)

		-- NEW: stop scanning paired nodes (see PutOp:preview for rationale).
		-- Remove both sides from the wait-queues as soon as they are reserved.
		if self.inq then
			unlink_get(ch, self)
		end
		if s.inq then
			unlink_put(ch, s)
		end

		-- Claim winner if participating.
		if sel and sel.winner == nil then
			sel.winner = self
		end

		signal(ch)

		if sel and sel.winner ~= self then
			return pending_preview(ch)
		end

		self.n = 1
		self[1] = s.val
		return nil, self.key, self
	end

	-- Not ready: enqueue and wait. If we previously claimed winner, release it.
	local changed = false

	if push_get(ch, self) then
		changed = true
	end

	if sel and sel.winner == self then
		sel.winner = nil
		changed = true
	end

	if changed then
		signal(ch)
	end

	return pending_preview(ch)
end

function GetOp:commit()
	if self.done then
		self.n = 1
		self[1] = self.result
		return self
	end

	local p = self.peer
	if not p then
		error('channel.get.commit: commit without a ready preview (no peer)', 0)
	end

	local sel = self._sel
	if sel and sel.winner ~= self then
		error('channel.get.commit: commit without a ready preview (lost arbitration)', 0)
	end

	commit_pair(self.ch, p, self)
	self.n = 1
	self[1] = self.result
	return self
end

function GetOp:abort()
	if self.done then return end

	local ch  = self.ch
	local sel = self._sel
	local changed = false

	-- If we were the current winner, release arbitration.
	if sel and sel.winner == self then
		sel.winner = nil
		changed = true
	end

	local p = self.peer
	if p and (not p.done) then
		if detach_uncommitted(p, self) then
			changed = true
		end
	end

	unlink_get(ch, self)
	self.peer = nil
	self.n = 0
	self[1] = nil

	-- Signal once if we changed arbitration or pairing state.
	if changed then
		signal(ch)
	end
end

----------------------------------------------------------------------
-- Direct-style convenience
----------------------------------------------------------------------

function Channel:put(val)
	return op.perform(self:put_op(val))
end

function Channel:get()
	return op.perform(self:get_op())
end

return {
	new     = Channel.new,
	Channel = Channel,
}

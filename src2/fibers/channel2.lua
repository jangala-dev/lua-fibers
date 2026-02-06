-- fibers/channel2.lua
--
-- Unbuffered rendezvous channel expressed as preview/commit ops with precise wakeups.
--
-- Purpose
--   Implements synchronous (unbuffered) put/get using the op2 protocol:
--   prepare is non-consuming (reservation only), and commit performs the rendezvous.
--
-- Semantics
--   * Channel:put_op(val) and Channel:get_op() return op objects implementing:
--       - preview(): establish or observe a match reservation without transferring data
--       - commit(offer): performs the rendezvous and transfers the value (must not yield)
--       - abort(offer?): rolls back reservations and leaves the op retryable
--   * The channel is unbuffered: put and get rendezvous directly.
--
-- Data structures
--   * Two intrusive FIFO queues: put list and get list.
--   * Each op object is also its own queue node (prev/next/inq), avoiding per-wait allocation.
--   * Matching is recorded via peer pointers (put.peer <-> get.peer) until committed/aborted.
--
-- Waiting and wake-ups (precise)
--   * The channel owns a single source Pulse (ch.pulse).
--   * Any state change that might enable progress signals ch.pulse (signal_if_waiting).
--   * Pending preview/commit return ch.pulse; no global coalescing pulse is used.
--
-- Choice integration
--   * get ops support optional _attach_select(sel) arbitration.
--   * Eligibility scanning respects sel.winner when present.
--
-- Optional stability hook
--   * put/get implement watch(offer) conservatively as ch.pulse, allowing derived ops to
--     await invalidation even when not holding reservations.

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

local function push_put(ch, n)
	if n.inq then return end
	n.prev = ch.put_t
	n.next = nil
	n.inq  = true
	if ch.put_t then ch.put_t.next = n else ch.put_h = n end
	ch.put_t = n
end

local function push_get(ch, n)
	if n.inq then return end
	n.prev = ch.get_t
	n.next = nil
	n.inq  = true
	if ch.get_t then ch.get_t.next = n else ch.get_h = n end
	ch.get_t = n
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

local function pending_commit(ch)
	return ch.pulse, nil
end

----------------------------------------------------------------------
-- Reservation/commit helpers
----------------------------------------------------------------------

local function bump(x) x.offer = x.offer + 1 end

local function detach_uncommitted(ch, a, b)
	local changed = false
	if a.peer == b then a.peer = nil; bump(a); changed = true end
	if b.peer == a then b.peer = nil; bump(b); changed = true end
	if changed then
		signal(ch)
	end
end

local function commit_pair(ch, putop, getop)
	if putop.done then return end

	putop.done   = true
	getop.done   = true
	getop.result = putop.val

	bump(putop)
	bump(getop)

	unlink_put(ch, putop)
	unlink_get(ch, getop)

	putop.peer = nil
	getop.peer = nil

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
		offer = 0,

		prev  = nil,
		next  = nil,
		inq   = false,
	}, PutOp)
end

function PutOp:watch(_offer)
	-- Conservative but correct: any channel state change may invalidate readiness.
	if self.done then return nil end
	return self.ch.pulse
end

function PutOp:preview()
	local ch = self.ch
	if self.done then
		return nil, self.offer, EMPTY
	end

	local g = self.peer
	if g then
		local sel = g._sel
		if sel and sel.winner ~= g then
			return pending_preview(ch)
		end
		return nil, self.offer, EMPTY
	end

	local r = find_eligible_get(ch.get_h)
	if r then
		self.peer = r
		r.peer    = self

		bump(self)
		bump(r)

		-- Reservation can unblock waiters.
		signal(ch)

		local sel = r._sel
		if sel and sel.winner == nil then
			-- Sender cannot be ready until receiver claims arbitration.
			return pending_preview(ch)
		end

		return nil, self.offer, EMPTY
	end

	push_put(ch, self)
	signal(ch)
	return pending_preview(ch)
end

function PutOp:commit(offer)
	local ch = self.ch

	if offer ~= self.offer then
		return pending_commit(ch)
	end
	if self.done then
		return nil, EMPTY
	end

	local g = self.peer
	if not g then
		return pending_commit(ch)
	end

	local sel = g._sel
	if sel and sel.winner ~= g then
		return pending_commit(ch)
	end

	commit_pair(ch, self, g)
	return nil, EMPTY
end

function PutOp:abort(_offer)
	if self.done then return end

	local ch = self.ch
	local g  = self.peer
	if g and (not g.done) then
		detach_uncommitted(ch, self, g)
	end

	unlink_put(ch, self)
	self.peer = nil
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
		offer  = 0,

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

function GetOp:watch(_offer)
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
		return nil, self.offer, payload_set(self, self.result)
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

		return nil, self.offer, payload_set(self, p.val)
	end

	local s = find_unmatched_put(ch.put_h)
	if s then
		self.peer = s
		s.peer    = self

		bump(self)
		bump(s)

		-- Claim winner if participating.
		if sel and sel.winner == nil then
			sel.winner = self
		end

		signal(ch)

		if sel and sel.winner ~= self then
			return pending_preview(ch)
		end

		return nil, self.offer, payload_set(self, s.val)
	end

	-- Not ready: enqueue and wait. If we previously claimed winner, release it.
	push_get(ch, self)

	if sel and sel.winner == self then
		sel.winner = nil
	end

	signal(ch)
	return pending_preview(ch)
end

function GetOp:commit(offer)
	local ch = self.ch

	if offer ~= self.offer then
		return pending_commit(ch)
	end
	if self.done then
		return nil, payload_set(self, self.result)
	end

	local p = self.peer
	if not p then
		return pending_commit(ch)
	end

	local sel = self._sel
	if sel and sel.winner ~= self then
		return pending_commit(ch)
	end

	commit_pair(ch, p, self)
	return nil, payload_set(self, self.result)
end

function GetOp:abort(_offer)
	if self.done then return end

	local ch  = self.ch
	local sel = self._sel

	-- If we were the current winner, release arbitration.
	if sel and sel.winner == self then
		sel.winner = nil
		-- Release can unblock other gets in the same choice.
		signal(ch)
	end

	local p  = self.peer
	if p and (not p.done) then
		detach_uncommitted(ch, p, self)
	end

	unlink_get(ch, self)
	self.peer = nil
	payload_clear(self)
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

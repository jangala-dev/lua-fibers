-- fibers/rendezvous.lua
--
-- Minimal rendezvous primitive for op2 (unbuffered only), “fast build” style:

local op = require 'fibers.op2'

local TAG_PENDING     = op.TAG_PENDING
local TAG_PREVIEW     = op.TAG_PREVIEW
local TAG_DONE        = op.TAG_DONE
local TAG_CANCELLED   = op.TAG_CANCELLED

local EMPTY           = op.EMPTY

-- Integer states (cheaper than strings in hot loops)
local ST_NEW, ST_QUEUED, ST_MATCHED, ST_DONE, ST_CANCELLED = 0, 1, 2, 3, 4

local function q_new()
	return { head = 1, tail = 0 }
end

local function q_push(q, x)
	local t = q.tail + 1
	q.tail = t
	q[t] = x
end

local function q_reset(q)
	q.head, q.tail = 1, 0
end

-- Pop first active queued element (single scan, no peek+pop)
local function q_pop_active(q)
	local h = q.head
	local t = q.tail

	while h <= t do
		local x = q[h]
		q[h] = nil
		h = h + 1

		if x and x.state == ST_QUEUED then
			q.head = h
			if h > t then q_reset(q) end
			return x
		end
	end

	q_reset(q)
	return nil
end

local function make(on_match)
	if type(on_match) ~= 'function' then on_match = nil end

	local sendq = q_new()
	local recvq = q_new()

	local function signal_offer(o)
		o.pulse:signal()
	end

	local function try_match()
		local s = q_pop_active(sendq)
		if not s then return end

		local r = q_pop_active(recvq)
		if not r then
			-- put sender back to queue if no receiver available
			s.state = ST_QUEUED
			q_push(sendq, s)
			return
		end

		s.state = ST_MATCHED
		r.state = ST_MATCHED
		s.peer  = r
		r.peer  = s
		s.committed, r.committed = false, false

		r.payload[1] = s.value
		r.payload.n  = 1

		if on_match then on_match(r, s) end

		-- Wake both sides to observe match.
		signal_offer(s)
		signal_offer(r)
	end

	local SendTicket = {}
	SendTicket.__index = SendTicket

	local RecvTicket = {}
	RecvTicket.__index = RecvTicket

	function SendTicket:pulse() return self.offer.pulse end
	function RecvTicket:pulse() return self.offer.pulse end

	local function ensure_send_queued(o)
		if o.state == ST_NEW then
			o.state = ST_QUEUED
			q_push(sendq, o)
			try_match()
		end
	end

	local function ensure_recv_queued(o)
		if o.state == ST_NEW then
			o.state = ST_QUEUED
			q_push(recvq, o)
			try_match()
		end
	end

	function SendTicket:preview(_ctx)
		local o = self.offer
		local st = o.state

		if st == ST_CANCELLED then
			return TAG_CANCELLED, nil, nil, nil
		end

		if st == ST_DONE then
			-- proposal is receiver offer (peer); peer may be retained, but commit ignores proposal when done
			return TAG_PREVIEW, o.peer, EMPTY, o.pulse
		end

		if st ~= ST_MATCHED then ensure_send_queued(o) end

		if o.state == ST_MATCHED then
			return TAG_PREVIEW, o.peer, EMPTY, o.pulse
		end

		return TAG_PENDING, nil, nil, o.pulse
	end

	function RecvTicket:preview(_ctx)
		local o = self.offer
		local st = o.state

		if st == ST_CANCELLED then
			return TAG_CANCELLED, nil, nil, nil
		end

		if st == ST_DONE then
			return TAG_PREVIEW, o, o.payload, o.pulse
		end

		if st ~= ST_MATCHED then ensure_recv_queued(o) end

		if o.state == ST_MATCHED then
			return TAG_PREVIEW, o, o.payload, o.pulse
		end

		return TAG_PENDING, nil, nil, o.pulse
	end

	-- Commit helpers: finalise by marking both done and signalling only the peer.
	local function finalise_and_wake_peer(self_offer, peer_offer)
		self_offer.state = ST_DONE
		peer_offer.state = ST_DONE
		-- peer may be blocked waiting on its pulse; wake it once.
		signal_offer(peer_offer)
	end

	function SendTicket:commit(_ctx, expected_proposal)
		local o = self.offer
		local st = o.state

		if st == ST_CANCELLED then
			return TAG_CANCELLED, nil, nil
		end
		if st == ST_DONE then
			return TAG_DONE, EMPTY, nil
		end

		local r = o.peer
		if st ~= ST_MATCHED or not r or expected_proposal ~= r then
			return TAG_PENDING, nil, o.pulse
		end

		if not o.committed then
			o.committed = true
			-- If peer already committed, finalise immediately with one wake.
			if r.committed and r.state == ST_MATCHED then
				finalise_and_wake_peer(o, r)
				return TAG_DONE, EMPTY, nil
			end
			-- Otherwise wake peer so it can commit.
			signal_offer(r)
		end

		-- Wait for peer to commit.
		return TAG_PENDING, nil, o.pulse
	end

	function RecvTicket:commit(_ctx, expected_proposal)
		local o = self.offer
		local st = o.state

		if st == ST_CANCELLED then
			return TAG_CANCELLED, nil, nil
		end
		if st == ST_DONE then
			return TAG_DONE, o.payload, nil
		end

		local s = o.peer
		if st ~= ST_MATCHED or not s or expected_proposal ~= o then
			return TAG_PENDING, nil, o.pulse
		end

		if not o.committed then
			o.committed = true
			if s.committed and s.state == ST_MATCHED then
				finalise_and_wake_peer(o, s)
				return TAG_DONE, o.payload, nil
			end
			signal_offer(s)
		end

		return TAG_PENDING, nil, o.pulse
	end

	-- Break match: restore the non-cancelling side to NEW so it can re-queue; signal both once.
	local function break_pair(cancelled_offer, other_offer)
		-- Detach
		cancelled_offer.peer = nil
		other_offer.peer = nil
		cancelled_offer.committed = false
		other_offer.committed = false

		if other_offer.payload then other_offer.payload.n = 0 end

		-- Let the other side re-attempt.
		if other_offer.state ~= ST_DONE and other_offer.state ~= ST_CANCELLED then
			other_offer.state = ST_NEW
		end

		-- Wake both so they observe the change.
		signal_offer(cancelled_offer)
		signal_offer(other_offer)
	end

	function SendTicket:cancel(_ctx)
		local o = self.offer
		if o.state == ST_DONE or o.state == ST_CANCELLED then return end

		local peer = o.peer
		o.state = ST_CANCELLED

		if peer and o.state == ST_CANCELLED and peer.state == ST_MATCHED then
			break_pair(o, peer)
			return
		end

		signal_offer(o)
	end

	function RecvTicket:cancel(_ctx)
		local o = self.offer
		if o.state == ST_DONE or o.state == ST_CANCELLED then return end

		local peer = o.peer
		o.state = ST_CANCELLED

		if peer and peer.state == ST_MATCHED and o.state == ST_CANCELLED then
			break_pair(o, peer)
			return
		end

		signal_offer(o)
	end

	local function send_op(val)
		return op.new_primitive(function(_ctx)
			local offer = {
				state     = ST_NEW,
				value     = val,
				peer      = nil,
				pulse     = op.new_pulse(),
				committed = false,
			}
			return setmetatable({ offer = offer }, SendTicket)
		end)
	end

	local function recv_op()
		return op.new_primitive(function(_ctx)
			local offer = {
				state     = ST_NEW,
				peer      = nil,
				pulse     = op.new_pulse(),
				payload   = { n = 0 },
				committed = false,
			}
			return setmetatable({ offer = offer }, RecvTicket)
		end)
	end

	return { send_op = send_op, recv_op = recv_op }
end

return { make = make }

-- fibers/rendezvous.lua
--
-- Minimal rendezvous primitive for op2 (unbuffered only), “fast build” style:
--   * no gate-state checks (perform controls gate)
--   * no defensive pcall or proposal mismatch checks beyond what is required for correctness
--   * invalidation always signals pulses

local op = require 'fibers.op2'

local TAG_PENDING     = op.TAG_PENDING
local TAG_PREVIEW     = op.TAG_PREVIEW
local TAG_DONE        = op.TAG_DONE
local TAG_CANCELLED   = op.TAG_CANCELLED

local EMPTY           = op.EMPTY

local ST_NEW       = 'state_new'
local ST_QUEUED    = 'state_queued'
local ST_MATCHED   = 'state_matched'
local ST_DONE      = 'state_done'
local ST_CANCELLED = 'state_cancelled'

-- Simple FIFO queue helpers -----------------------------------------

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

local function q_peek_active(q)
	local h = q.head
	local t = q.tail

	while h <= t do
		local x = q[h]
		if x and x.state == ST_QUEUED then
			q.head = h
			return x
		end
		q[h] = nil
		h = h + 1
	end

	q_reset(q)
	return nil
end

local function q_pop_head(q)
	local h = q.head
	local t = q.tail
	if h > t then
		q_reset(q)
		return nil
	end

	local x = q[h]
	q[h] = nil
	h = h + 1
	q.head = h
	if h > t then q_reset(q) end
	return x
end

local function q_unqueue(o)
	if o.state == ST_QUEUED then
		o.state = ST_NEW
	end
end

-- Rendezvous core ----------------------------------------------------

local function make(on_match)
	if type(on_match) ~= 'function' then
		on_match = function() end
	end

	local sendq = q_new()
	local recvq = q_new()

	local function signal(o)
		o.pulse:signal()
	end

	local function break_pair(r)
		local s = r and r.peer or nil
		if not r or not s then return end

		r.peer, s.peer = nil, nil
		r.proposal, s.proposal = nil, nil

		if r.state ~= ST_DONE and r.state ~= ST_CANCELLED then r.state = ST_NEW end
		if s.state ~= ST_DONE and s.state ~= ST_CANCELLED then s.state = ST_NEW end

		r.committed, s.committed = false, false

		if r.payload then
			r.payload.n = 0
		end

		signal(r)
		signal(s)
	end

	local function finalise_pair(r)
		local s = r.peer
		r.state = ST_DONE
		s.state = ST_DONE
		signal(r)
		signal(s)
	end

	local function try_match()
		local s = q_peek_active(sendq)
		local r = q_peek_active(recvq)
		if not s or not r then return end

		s = q_pop_head(sendq)
		r = q_pop_head(recvq)
		if not s or not r then return end

		s.state = ST_MATCHED
		r.state = ST_MATCHED
		s.peer  = r
		r.peer  = s

		-- Proposal identity is receiver offer r.
		s.proposal = r
		r.proposal = r

		s.committed, r.committed = false, false

		r.payload[1] = s.value
		r.payload.n  = 1

		on_match(r, s)

		signal(s)
		signal(r)
	end

	-- Tickets ----------------------------------------------------------

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

		if o.state == ST_CANCELLED then
			return TAG_CANCELLED, nil, nil, nil
		end

		if o.state == ST_DONE then
			return TAG_PREVIEW, o.proposal, EMPTY, o.pulse
		end

		if o.state ~= ST_MATCHED then
			ensure_send_queued(o)
		end

		if o.state == ST_MATCHED then
			return TAG_PREVIEW, o.proposal, EMPTY, o.pulse
		end

		return TAG_PENDING, nil, nil, o.pulse
	end

	function RecvTicket:preview(_ctx)
		local o = self.offer

		if o.state == ST_CANCELLED then
			return TAG_CANCELLED, nil, nil, nil
		end

		if o.state == ST_DONE then
			return TAG_PREVIEW, o.proposal, o.payload, o.pulse
		end

		if o.state ~= ST_MATCHED then
			ensure_recv_queued(o)
		end

		if o.state == ST_MATCHED then
			return TAG_PREVIEW, o.proposal, o.payload, o.pulse
		end

		return TAG_PENDING, nil, nil, o.pulse
	end

	function SendTicket:commit(_ctx, expected_proposal)
		local o = self.offer

		if o.state == ST_CANCELLED then
			return TAG_CANCELLED, nil, nil
		end

		if o.state == ST_DONE then
			return TAG_DONE, EMPTY, nil
		end

		-- Reify only expected proposal.
		if o.proposal ~= expected_proposal or o.state ~= ST_MATCHED or not o.peer then
			return TAG_PENDING, nil, o.pulse
		end

		local r = o.peer
		if not o.committed then
			o.committed = true
			signal(r)
		end

		if r.state == ST_MATCHED and r.committed then
			finalise_pair(r)
			return TAG_DONE, EMPTY, nil
		end

		return TAG_PENDING, nil, o.pulse
	end

	function RecvTicket:commit(_ctx, expected_proposal)
		local o = self.offer

		if o.state == ST_CANCELLED then
			return TAG_CANCELLED, nil, nil
		end

		if o.state == ST_DONE then
			return TAG_DONE, o.payload, nil
		end

		if o.proposal ~= expected_proposal or o.state ~= ST_MATCHED or not o.peer then
			return TAG_PENDING, nil, o.pulse
		end

		local s = o.peer
		if not o.committed then
			o.committed = true
			signal(s)
		end

		if s.state == ST_MATCHED and s.committed then
			finalise_pair(o)
			return TAG_DONE, o.payload, nil
		end

		return TAG_PENDING, nil, o.pulse
	end

	function SendTicket:cancel(_ctx)
		local o = self.offer
		if o.state == ST_DONE then return end
		o.state = ST_CANCELLED
		q_unqueue(o)
		if o.peer then break_pair(o.peer) end
		o.proposal = nil
		signal(o)
	end

	function RecvTicket:cancel(_ctx)
		local o = self.offer
		if o.state == ST_DONE then return end
		o.state = ST_CANCELLED
		q_unqueue(o)
		if o.peer then break_pair(o) end
		o.proposal = nil
		signal(o)
	end

	-- Constructors ------------------------------------------------------

	local function send_op(val)
		return op.new_primitive(function(_ctx)
			local offer = {
				state     = ST_NEW,
				value     = val,
				peer      = nil,
				proposal  = nil,
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
				proposal  = nil,
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

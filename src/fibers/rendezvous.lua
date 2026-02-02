-- fibers/rendezvous_teach.lua
--
-- Minimal, readable rendezvous primitive for op2 (unbuffered only).
--

local op = require 'fibers.op2'

local GATE_COMMITTING = op.GATE_COMMITTING
local GATE_ABORTED    = op.GATE_ABORTED

local TAG_PENDING     = op.TAG_PENDING
local TAG_PREVIEW     = op.TAG_PREVIEW
local TAG_DONE        = op.TAG_DONE
local TAG_CANCELLED   = op.TAG_CANCELLED

local EMPTY           = op.EMPTY

-- Offer states (strings retained)
local ST_NEW       = 'state_new'
local ST_QUEUED    = 'state_queued'
local ST_MATCHED   = 'state_matched'
local ST_DONE      = 'state_done'
local ST_CANCELLED = 'state_cancelled'

-- Simple FIFO queue helpers -----------------------------------------
-- Queue is a table with numeric slots plus head/tail indices.
-- Stale entries are skipped (state ~= ST_QUEUED).

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

-- Peek the first still-queued offer, skipping stale entries.
-- Does not remove the returned entry.
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

-- Pop the (current) head entry. Caller should have ensured it's active.
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

-- Best-effort removal: mark stale; peek/pop will skip it later.
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
		-- Must not yield; Pulse.signal schedules tasks.
		o.pulse:signal()
	end

	local function break_pair(r)
		-- Proposal identity is receiver offer r.
		local s = r and r.peer or nil
		if not r or not s then return end

		r.peer, s.peer = nil, nil
		if r.state ~= ST_DONE then r.state = ST_NEW end
		if s.state ~= ST_DONE then s.state = ST_NEW end

		r.committed, s.committed = false, false
		r.nudged,    s.nudged    = false, false

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
		-- Only remove from queues once we know we have a pair.
		local s = q_peek_active(sendq)
		local r = q_peek_active(recvq)
		if not s or not r then return end

		-- Now remove the heads we just peeked.
		s = q_pop_head(sendq)
		r = q_pop_head(recvq)
		if not s or not r then return end

		-- Establish match: proposal identity is receiver offer r.
		s.state = ST_MATCHED
		r.state = ST_MATCHED
		s.peer  = r
		r.peer  = s

		s.committed, r.committed = false, false
		s.nudged,    r.nudged    = false, false

		-- Populate receiver payload from sender value.
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

	function SendTicket:pulse()
		return self.offer.pulse
	end

	function RecvTicket:pulse()
		return self.offer.pulse
	end

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

	function SendTicket:preview(ctx)
		local o = self.offer
		if ctx.gate_state == GATE_ABORTED or o.state == ST_CANCELLED then
			return TAG_CANCELLED, nil, nil, nil
		end

		if o.state == ST_DONE then
			return TAG_PREVIEW, o.peer, EMPTY, o.pulse
		end

		if o.state ~= ST_MATCHED then
			ensure_send_queued(o)
		end

		if o.state == ST_MATCHED then
			return TAG_PREVIEW, o.peer, EMPTY, o.pulse
		end

		return TAG_PENDING, nil, nil, o.pulse
	end

	function RecvTicket:preview(ctx)
		local o = self.offer
		if ctx.gate_state == GATE_ABORTED or o.state == ST_CANCELLED then
			return TAG_CANCELLED, nil, nil, nil
		end

		if o.state == ST_DONE then
			return TAG_PREVIEW, o, o.payload, o.pulse
		end

		if o.state ~= ST_MATCHED then
			ensure_recv_queued(o)
		end

		if o.state == ST_MATCHED then
			return TAG_PREVIEW, o, o.payload, o.pulse
		end

		return TAG_PENDING, nil, nil, o.pulse
	end

	function SendTicket:commit(ctx)
		local o = self.offer
		if ctx.gate_state == GATE_ABORTED or o.state == ST_CANCELLED then
			return TAG_CANCELLED, nil, nil, nil
		end
		if ctx.gate_state ~= GATE_COMMITTING then
			return TAG_CANCELLED, nil, nil, nil
		end

		if o.state == ST_DONE then
			return TAG_DONE, o.peer, EMPTY, nil
		end

		if o.state ~= ST_MATCHED or not o.peer then
			return TAG_CANCELLED, nil, nil, nil
		end

		o.committed = true
		local r = o.peer

		if r.state == ST_MATCHED and r.committed then
			finalise_pair(r)
			return TAG_DONE, r, EMPTY, nil
		end

		-- Nudge peer once.
		if not o.nudged then
			o.nudged = true
			signal(r)
		end

		return TAG_PENDING, nil, nil, o.pulse
	end

	function RecvTicket:commit(ctx)
		local o = self.offer
		if ctx.gate_state == GATE_ABORTED or o.state == ST_CANCELLED then
			return TAG_CANCELLED, nil, nil, nil
		end
		if ctx.gate_state ~= GATE_COMMITTING then
			return TAG_CANCELLED, nil, nil, nil
		end

		if o.state == ST_DONE then
			return TAG_DONE, o, o.payload, nil
		end

		if o.state ~= ST_MATCHED or not o.peer then
			return TAG_CANCELLED, nil, nil, nil
		end

		o.committed = true
		local s = o.peer

		if s.state == ST_MATCHED and s.committed then
			finalise_pair(o)
			return TAG_DONE, o, o.payload, nil
		end

		if not o.nudged then
			o.nudged = true
			signal(s)
		end

		return TAG_PENDING, nil, nil, o.pulse
	end

	function SendTicket:cancel(_ctx)
        if o.state == ST_DONE then return end
		local o = self.offer
		o.state = ST_CANCELLED
		q_unqueue(o)
		if o.peer then break_pair(o.peer) end
		signal(o)
	end

	function RecvTicket:cancel(_ctx)
        if o.state == ST_DONE then return end
		local o = self.offer
		o.state = ST_CANCELLED
		q_unqueue(o)
		if o.peer then break_pair(o) end
		signal(o)
	end

	-- Constructors ------------------------------------------------------

	local function send_op(val)
		return op.new_primitive(function(_ctx)
			local offer = {
				state     = ST_NEW,
				value     = val,
				peer      = nil,
				pulse     = op.new_pulse(),
				committed = false,
				nudged    = false,
			}
			return setmetatable({ offer = offer }, SendTicket)
		end)
	end

	local function recv_op()
		return op.new_primitive(function(_ctx)
			local offer = {
				state     = ST_NEW,
				value     = nil,
				peer      = nil,
				pulse     = op.new_pulse(),
				payload   = { n = 0 },
				committed = false,
				nudged    = false,
			}
			return setmetatable({ offer = offer }, RecvTicket)
		end)
	end

	return { send_op = send_op, recv_op = recv_op }
end

return { make = make }

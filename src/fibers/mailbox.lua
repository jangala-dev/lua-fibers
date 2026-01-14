-- fibers/mailbox.lua
--
-- Mailbox: closeable, drainable queue for fibers.
--
-- Conventions
--   * nil payloads are forbidden; nil is reserved for end-of-stream.
--   * rx:recv() returns:
--       - a non-nil message, or
--       - nil when the mailbox is closed and drained.
--     rx:why() yields the close reason (if any).
--   * tx:send(v) returns:
--       - true if accepted/delivered,
--       - nil if the mailbox is closed (send rejected).
--     tx:why() yields the close reason (if any).
--   * Multi-producer:
--       - tx:clone() creates a new counted sender handle.
--       - each counted handle should be closed once finished.
--       - mailbox closes-for-send when the last counted handle closes.
--
-- Full policies (when no receiver is waiting and the mailbox is full):
--   * "block"       : sender blocks until space/receiver is available (default)
--   * "drop_newest" : drop the incoming value; send succeeds immediately
--   * "drop_oldest" : drop the oldest buffered value (if any), enqueue the new one; send succeeds immediately
--
-- For rendezvous mailboxes (capacity == 0), "drop_oldest" behaves like "drop_newest".

---@module 'fibers.mailbox'

local op      = require 'fibers.op'
local fifo    = require 'fibers.utils.fifo'
local perform = require 'fibers.performer'.perform

---@alias MailboxWant nil  -- reserved for future extensions

---@class MailboxState
---@field cap integer
---@field buf any|nil      -- FIFO buffer when cap>0; nil for rendezvous
---@field getq any         -- FIFO of waiting receivers
---@field putq any         -- FIFO of waiting senders
---@field closed boolean
---@field reason any|nil
---@field senders integer  -- counted sender handles still open
---@field full '"block"'|'"drop_newest"'|'"drop_oldest"'
---@field dropped integer  -- total number of dropped messages due to full policy

---@class MailboxTx
---@field _st MailboxState
---@field _closed boolean    -- this handle closed (idempotent)
---@field _counted boolean   -- whether this handle contributes to st.senders
local Tx = {}
Tx.__index = Tx

---@class MailboxRx
---@field _st MailboxState
local Rx = {}
Rx.__index = Rx

----------------------------------------------------------------------
-- Internal helpers
----------------------------------------------------------------------

--- Pop the next entry whose suspension is still waiting, if any.
---@param q any
---@return table|nil
local function pop_active(q)
	while not q:empty() do
		local e = q:pop()
		local s = e.suspension
		if not s or s:waiting() then
			return e
		end
	end
end

---@param st MailboxState
---@param reason any|nil
local function record_reason(st, reason)
	if st.reason == nil and reason ~= nil then
		st.reason = reason
	end
end

--- Close the mailbox state (idempotent), record reason, and wake blocked parties.
--- Receivers drain buffered values (if any), then receive nil.
--- Waiting senders are rejected (nil).
---@param st MailboxState
---@param reason any|nil
local function close_state(st, reason)
	if st.closed then
		record_reason(st, reason)
		return
	end

	st.closed = true
	record_reason(st, reason)

	-- Wake receivers: deliver buffered values first, then nil when buffer empty.
	while true do
		local recv = pop_active(st.getq)
		if not recv then break end

		local v
		if st.buf and st.buf:length() > 0 then
			v = st.buf:pop()
		end
		recv.suspension:complete(recv.wrap, v)
	end

	-- Reject senders.
	while true do
		local snd = pop_active(st.putq)
		if not snd then break end
		snd.suspension:complete(snd.wrap, nil)
	end
end

----------------------------------------------------------------------
-- Construction
----------------------------------------------------------------------

---@param full any
---@return '"block"'|'"drop_newest"'|'"drop_oldest"'
local function norm_full_policy(full, capacity)
	if full == nil then full = 'block' end
	if full ~= 'block' and full ~= 'drop_newest' and full ~= 'drop_oldest' then
		error('mailbox.new: invalid full policy: ' .. tostring(full), 3)
	end
	-- Rendezvous mailboxes have no buffer; drop_oldest collapses to drop_newest.
	if capacity == 0 and full == 'drop_oldest' then
		full = 'drop_newest'
	end
	return full
end

--- Create a mailbox. Returns (tx, rx).
---@param capacity? integer  # 0 or nil -> rendezvous; >0 -> buffered capacity
---@param opts? { full?: '"block"'|'"drop_newest"'|'"drop_oldest"' }
---@return MailboxTx tx, MailboxRx rx
local function new(capacity, opts)
	capacity = capacity or 0
	opts = opts or {}
	local full = norm_full_policy(opts.full, capacity)

	---@type MailboxState
	local st = {
		cap     = capacity,
		buf     = (capacity > 0) and fifo.new() or nil,
		getq    = fifo.new(),
		putq    = fifo.new(),
		closed  = false,
		reason  = nil,
		senders = 1,
		full    = full,
		dropped = 0,
	}

	local tx = setmetatable({ _st = st, _closed = false, _counted = true }, Tx)
	local rx = setmetatable({ _st = st }, Rx)
	return tx, rx
end

----------------------------------------------------------------------
-- Tx (sender)
----------------------------------------------------------------------

--- Return the mailbox close reason (if any).
---@return any|nil
function Tx:why()
	return self._st.reason
end

--- Return total number of dropped messages due to the full policy.
---@return integer
function Tx:dropped()
	return self._st.dropped or 0
end

--- Clone this sender handle (multi-producer).
--- If the mailbox or this handle is closed, returns an inert, uncounted handle.
---@return MailboxTx
function Tx:clone()
	local st = self._st
	if self._closed or st.closed then
		return setmetatable({ _st = st, _closed = true, _counted = false }, Tx)
	end
	st.senders = st.senders + 1
	return setmetatable({ _st = st, _closed = false, _counted = true }, Tx)
end

--- Close this sender handle (idempotent).
--- When the last counted sender closes, the mailbox closes-for-send.
---@param reason any|nil
---@return boolean ok
function Tx:close(reason)
	local st = self._st
	record_reason(st, reason)

	if self._closed then return true end

	self._closed = true

	-- If already uncounted, or mailbox already closed, nothing to do.
	if not self._counted or st.closed then
		self._counted = false
		return true
	end

	self._counted = false
	st.senders = st.senders - 1
	if st.senders <= 0 then
		st.senders = 0
		close_state(st, reason)
	end

	return true
end

--- Op that sends a message.
--- When performed: true on success, nil when closed (send rejected).
---@param v any  # MUST NOT be nil
---@return Op
function Tx:send_op(v)
	assert(v ~= nil, 'mailbox.send: nil payload is not permitted')

	local st = self._st
	local getq, putq, buf, cap = st.getq, st.putq, st.buf, st.cap
	local full = st.full

	local function handle_full()
		if full == 'block' then
			return false
		end
		st.dropped = st.dropped + 1
		if full == 'drop_oldest' and buf then
			-- buffer is full, so there is an oldest element to evict
			buf:pop()
			buf:push(v)
		end
		-- drop_newest does nothing further (discard v)
		return true
	end

	local function try()
		if st.closed or self._closed then
			return true, nil
		end

		-- Rendezvous with a waiting receiver.
		local recv = pop_active(getq)
		if recv then
			recv.suspension:complete(recv.wrap, v)
			return true, true
		end

		-- Buffered enqueue when there is space.
		if buf and buf:length() < cap then
			buf:push(v)
			return true, true
		end

		-- Full (buffered) or no receiver (rendezvous): apply full policy.
		if handle_full() then
			return true, true
		end
		return false
	end

	local function block(suspension, wrap_fn)
		if st.closed or self._closed then
			return suspension:complete(wrap_fn, nil)
		end
		putq:push { val = v, suspension = suspension, wrap = wrap_fn }
	end

	return op.new_primitive(nil, try, block)
end

--- Synchronously send a message.
---@param v any
---@return boolean|nil ok
function Tx:send(v)
	return perform(self:send_op(v))
end

----------------------------------------------------------------------
-- Rx (receiver)
----------------------------------------------------------------------

--- Return the mailbox close reason (if any).
---@return any|nil
function Rx:why()
	return self._st.reason
end

--- Return total number of dropped messages due to the full policy.
---@return integer
function Rx:dropped()
	return self._st.dropped or 0
end

--- Op that receives the next message.
--- When performed: a non-nil value, or nil when closed and drained.
---@return Op
function Rx:recv_op()
	local st = self._st
	local getq, putq, buf = st.getq, st.putq, st.buf

	local function try()
		-- Prefer unblocking a waiting sender (if present); we may still return
		-- a buffered value first.
		local snd = pop_active(putq)
		if snd then snd.suspension:complete(snd.wrap, true) end

		if buf and buf:length() > 0 then
			local v = buf:pop()
			if snd then buf:push(snd.val) end
			return true, v
		end

		if snd then
			return true, snd.val
		end

		if st.closed then
			return true, nil
		end

		return false
	end

	---@param suspension Suspension
	---@param wrap_fn WrapFn
	local function block(suspension, wrap_fn)
		if st.closed then
			return suspension:complete(wrap_fn, nil)
		end
		getq:push { suspension = suspension, wrap = wrap_fn }
	end

	return op.new_primitive(nil, try, block)
end

--- Synchronously receive the next message.
---@return any|nil v
function Rx:recv()
	return perform(self:recv_op())
end

--- Iterator over received messages, ending at nil (closed and drained).
---@return fun(): any|nil
function Rx:iter()
	return function ()
		return self:recv()
	end
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

return {
	new = new,

	Tx = Tx,
	Rx = Rx,
}

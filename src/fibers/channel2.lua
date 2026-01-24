-- fibers/channel2.lua
--
-- Unbuffered rendezvous channel for op2 (transactional events).
--   * put_op(v) completes when a receiver commits a match (or matches a waiting receiver).
--   * get_op() completes with the sent value.
--   * nil payloads are permitted.
--
-- Uses:
--   * dlist for offer queues (O(1) unlink on abort/match)
--   * fifo for waiter queues (lazy unlink via entry.active)

local op2   = require 'fibers.op2'
local fifo  = require 'fibers.utils.fifo'
local dlist = require 'fibers.utils.dlist'

---@class Channel2
---@field _putq DList
---@field _getq DList
---@field _putw any   -- fifo of waiting puter tasks
---@field _getw any   -- fifo of waiting receiver tasks
local Channel2 = {}
Channel2.__index = Channel2

local function new()
	return setmetatable({
		_putq = dlist.new(),
		_getq = dlist.new(),
		_putw = fifo.new(),
		_getw = fifo.new(),
	}, Channel2)
end

----------------------------------------------------------------------
-- Waiters (frontier subscriptions)
----------------------------------------------------------------------

local function wake_all(q)
	while not q:empty() do
		local e = q:pop()
		if e and e.active then
			e.active = false
			e.waker:wakeup(e.task)
		end
	end
end

local function notify_put(ch) wake_all(ch._putw) end
local function notify_get(ch) wake_all(ch._getw) end
local function notify_both(ch)
	notify_put(ch); notify_get(ch)
end

local function register_waiter(q, task, waker)
	local e = { task = task, waker = waker, active = true }
	q:push(e)
	return {
		unlink = function ()
			if not e.active then return false end
			e.active = false
			return false
		end,
	}
end

----------------------------------------------------------------------
-- Offers (queued rendezvous intents)
----------------------------------------------------------------------

-- Offer value shape:
--   kind  : 'put'|'get'
--   done  : boolean
--   val   : any         (put only; may be nil)
--   res   : any         (get only; may be nil)
--   _node : DListNode|nil

local function peek_waiting_offer(list)
	-- Best-effort defensive pruning of stale/done nodes.
	local n = list.head
	while n do
		local off = n.value
		if off and not off.done then
			return n, off
		end
		local nextn = n.next
		n:remove()
		n = nextn
	end
	return nil
end

local function enqueue_offer(ch, st, kind, val)
	if st.offer then
		return st.offer
	end

	local off = { kind = kind, done = false, val = val, res = nil, _node = nil }
	local list = (kind == 'put') and ch._putq or ch._getq
	local node = list:push_tail(off)

	off._node = node
	st.offer  = off

	-- On abort (losing a choice / performer exit), withdraw the offer if still queued.
	op2.add_cleanup(st, function ()
		local n = off._node
		if n and n.list then
			n:remove()
			off._node = nil
			if not off.done then
				if kind == 'put' then notify_get(ch) else notify_put(ch) end
			end
		end
	end)

	-- Arrival may enable the opposite side to match immediately.
	if kind == 'put' then notify_get(ch) else notify_put(ch) end
	return off
end

----------------------------------------------------------------------
-- Match records (publication via Txn:commit -> apply)
----------------------------------------------------------------------

local function rec_match_get(ch, get_node, get_off, v)
	return {
		validate = function ()
			if get_off.done then return 'RETRY' end
			if not (get_node and get_node.list) then return 'RETRY' end
			return 'OK'
		end,
		apply = function ()
			-- Publication point: remove offer and store result.
			if get_node and get_node.list then get_node:remove() end
			get_off._node = nil
			get_off.res   = v
			get_off.done  = true
			notify_both(ch)
			return 'OK'
		end,
		abort = function () end, -- must be safe post-commit; no-op is fine
	}
end

local function rec_match_put(ch, put_node, put_off)
	return {
		validate = function ()
			if put_off.done then return 'RETRY' end
			if not (put_node and put_node.list) then return 'RETRY' end
			return 'OK'
		end,
		apply = function ()
			if put_node and put_node.list then put_node:remove() end
			put_off._node = nil
			put_off.done  = true
			notify_both(ch)
			return 'OK'
		end,
		abort = function () end,
	}
end

----------------------------------------------------------------------
-- Op constructors
----------------------------------------------------------------------

local function put_poll(self, _txn, st)
	local ch, v = self._ch, self._v

	-- If we are already queued, we only complete once a receiver has matched us.
	local off = st.offer
	if off then
		if off.done then
			return 'READY', nil, true
		end
		return 'WAIT', 'get'
	end

	-- Fast path: match an already-waiting receiver without enqueueing ourselves.
	local rnode, roff = peek_waiting_offer(ch._getq)
	if rnode then
		return 'READY', rec_match_get(ch, rnode, roff, v), true
	end

	-- Otherwise, enqueue and wait.
	enqueue_offer(ch, st, 'put', v)
	return 'WAIT', 'get'
end

local function put_block(self, _st, task, waker, _want)
	return register_waiter(self._ch._putw, task, waker)
end

function Channel2:put_op(v)
	local o = op2.prim(put_poll, put_block)
	o._ch   = self
	o._v    = v
	return o
end

local function get_poll(self, _txn, st)
	local ch = self._ch

	-- If we are already queued, we only complete once a puter has matched us.
	local off = st.offer
	if off then
		if off.done then
			return 'READY', nil, off.res
		end
		return 'WAIT', 'put'
	end

	-- Fast path: match an already-waiting puter and return its value.
	local snode, soff = peek_waiting_offer(ch._putq)
	if snode then
		return 'READY', rec_match_put(ch, snode, soff), soff.val
	end

	-- Otherwise, enqueue and wait.
	enqueue_offer(ch, st, 'get', nil)
	return 'WAIT', 'put'
end

local function get_block(self, _st, task, waker, _want)
	return register_waiter(self._ch._getw, task, waker)
end

function Channel2:get_op()
	local o = op2.prim(get_poll, get_block)
	o._ch = self
	return o
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

return {
	new = new,
	Channel2 = Channel2,
}

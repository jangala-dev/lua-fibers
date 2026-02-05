-- fibers/runtime2.lua
--
-- Targeted waiting:
-- * runtime.await(waitable) subscribes a per-fibre wait token to the waitable and yields WAIT.
-- * waitable may be a source pulse or a derived 'any' waitable (both support :subscribe(token, epoch)).
--
-- Safety:
-- * Each await increments an epoch, stored in fib._waiting_epoch.
-- * Wakes validate (token identity, epoch) before scheduling the fibre.
-- * Wakes cancel remaining subscriptions before scheduling.

local sched_mod = require 'fibers.sched2'

local runtime = {}

runtime.sched = sched_mod.new()

local WAIT = {}  -- unique sentinel

local _current_fiber = nil
runtime._live = {}

----------------------------------------------------------------------
-- Wait token (one per fibre)
----------------------------------------------------------------------

local WaitToken = {}
WaitToken.__index = WaitToken

function WaitToken.new(fib)
	return setmetatable({
		fib     = fib,
		epoch   = 0,

		-- Triples: [pulse, idx, epoch] per handle.
		handles = {},
		nh      = 0, -- number of handles (triples)
	}, WaitToken)
end

function WaitToken:_begin_wait()
	self.epoch = self.epoch + 1
	self.nh = 0
	return self.epoch
end

function WaitToken:_subscribed_to(pulse, epoch)
	local hs = self.handles
	for i = 1, self.nh do
		local j = (i - 1) * 3 + 1
		if hs[j] == pulse and hs[j + 3 - 1] == epoch then
			return true
		end
	end
	return false
end

function WaitToken:_add_handle(pulse, idx, epoch)
	local n = self.nh + 1
	self.nh = n
	local hs = self.handles
	local j = (n - 1) * 3 + 1
	hs[j]     = pulse
	hs[j + 1] = idx
	hs[j + 2] = epoch
end

function WaitToken:_moved(pulse, old_idx, new_idx, epoch)
	-- Update the stored index for (pulse, epoch, old_idx).
	local hs = self.handles
	for i = 1, self.nh do
		local j = (i - 1) * 3 + 1
		if hs[j] == pulse and hs[j + 1] == old_idx and hs[j + 2] == epoch then
			hs[j + 1] = new_idx
			return
		end
	end
end

function WaitToken:_cancel_all()
	local hs = self.handles
	for i = 1, self.nh do
		local j = (i - 1) * 3 + 1
		local p     = hs[j]
		local idx   = hs[j + 1]
		local epoch = hs[j + 2]

		-- Best-effort: validate at pulse side.
		p:_unsubscribe_at(idx, self, epoch)

		hs[j], hs[j + 1], hs[j + 2] = nil, nil, nil
	end
	self.nh = 0
end

function WaitToken:_woken_by(_pulse, sched, epoch)
	local fib = self.fib

	-- Validate: this wake must correspond to the fibre's current wait.
	if fib._waiting_token ~= self or fib._waiting_epoch ~= epoch then
		return
	end

	-- Cancel remaining subscriptions before rescheduling.
	self:_cancel_all()

	fib._waiting_waitable = nil
	fib._waiting_token    = nil
	fib._waiting_epoch    = nil

	sched:schedule(fib)
end

----------------------------------------------------------------------
-- Runtime API
----------------------------------------------------------------------

function runtime.await(waitable)
	local fib = _current_fiber
	if not fib then error('await must be called from inside a fibre', 2) end
	if fib._waiting_token ~= nil then
		error('await called while already waiting', 2)
	end

	local tok = fib._wait_token
	local epoch = tok:_begin_wait()

	fib._waiting_waitable = waitable
	fib._waiting_token    = tok
	fib._waiting_epoch    = epoch

	waitable:subscribe(tok, epoch)
	return coroutine.yield(WAIT)
end

function runtime.scheduler()
	return runtime.sched
end

function runtime.current_fiber()
	return _current_fiber
end

----------------------------------------------------------------------
-- Fibre task
----------------------------------------------------------------------

local Fiber = {}
Fiber.__index = Fiber

function Fiber.new(fn, name)
	local f = setmetatable({
		co = coroutine.create(fn),
		name = name or '<fiber>',
		_queued = false,

		_waiting_waitable = nil,
		_waiting_token    = nil,
		_waiting_epoch    = nil,

		_wait_token = nil,
	}, Fiber)
	f._wait_token = WaitToken.new(f)
	return f
end

function Fiber:run(_)
	local saved = _current_fiber
	_current_fiber = self

	local ok, yielded = coroutine.resume(self.co)

	_current_fiber = saved

	if ok == false then
		runtime._live[self] = nil
		error(('fiber %s crashed: %s'):format(self.name, tostring(yielded)))
	end

	if coroutine.status(self.co) == 'dead' then
		runtime._live[self] = nil
		return
	end

	if yielded == WAIT then
		return
	end

	runtime._live[self] = nil
	error(('fiber %s yielded unexpected value'):format(self.name), 0)
end

function runtime.spawn(fn, name)
	local f = Fiber.new(fn, name)
	runtime._live[f] = true
	runtime.sched:schedule(f)
	return f
end

function runtime.step()
	if runtime.sched:step() then
		return 'ran'
	end

	local any = next(runtime._live)
	if not any then
		return 'done'
	end

	for fib in pairs(runtime._live) do
		if fib._waiting_waitable == nil then
			error('deadlock: no runnable tasks (live fibre not runnable and not waiting)', 0)
		end
	end

	error('deadlock: no runnable tasks (all fibres appear to be waiting)', 0)
end

function runtime.main()
	while true do
		if runtime.step() == 'done' then return end
	end
end

return runtime

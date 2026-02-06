-- fibers/runtime2.lua
--
-- Runtime: fibres + scheduler integration with targeted waiting (token/epoch).
--
-- Purpose
--   Turns Lua coroutines into scheduled fibre Tasks and enforces a single blocking protocol:
--   fibres may block only by calling runtime.await(waitable), which yields a sentinel and
--   subscribes the fibre's wait token to the waitable.
--
-- Fibre model
--   * A fibre is a Task with :run(sched) that resumes a coroutine.
--   * The scheduler is cooperative: a fibre runs until it yields WAIT or terminates.
--
-- Waiting protocol
--   * runtime.await(waitable):
--       - increments the fibre token epoch,
--       - records (_waiting_token, _waiting_epoch, _waiting_waitable),
--       - calls waitable:subscribe(token, epoch),
--       - yields the WAIT sentinel.
--   * Wakes are delivered through WaitToken:_woken_by(pulse, sched, epoch):
--       - validates that the wake matches the fibre's current epoch,
--       - cancels all outstanding subscriptions for that epoch,
--       - clears waiting state,
--       - schedules the fibre.
--
-- Deadlock detection
--   * If the scheduler has no runnable tasks and there exist live fibres:
--       - if all live fibres are waiting, error "deadlock: all fibres appear to be waiting"
--       - otherwise, error "deadlock: live fibre not runnable and not waiting"
--
-- API
--   * runtime.spawn(fn, name?) -> fibre
--   * runtime.await(waitable)
--   * runtime.step() -> 'ran' | 'done' | error
--   * runtime.main()
--   * runtime.scheduler() -> scheduler
--   * runtime.current_fiber() -> fibre|nil

local sched_mod = require 'fibers.sched2'

local runtime = {}
runtime.sched = sched_mod.new()

local WAIT = {} -- unique sentinel

local _current_fiber = nil
runtime._live = {}

----------------------------------------------------------------------
-- Wait token (one per fibre)
----------------------------------------------------------------------

local WaitToken = {}
WaitToken.__index = WaitToken

function WaitToken.new(fib)
	return setmetatable({
		fib   = fib,
		epoch = 0,

		-- triples: [pulse, idx, epoch]
		hs = {},
		nh = 0,
	}, WaitToken)
end

function WaitToken:_begin_wait()
	self.epoch = self.epoch + 1
	self.nh = 0
	return self.epoch
end

function WaitToken:_add_handle(pulse, idx, epoch)
	local n = self.nh + 1
	self.nh = n
	local hs = self.hs
	local j = (n - 1) * 3 + 1
	hs[j]     = pulse
	hs[j + 1] = idx
	hs[j + 2] = epoch
end

function WaitToken:_cancel_all()
	local hs = self.hs
	for i = 1, self.nh do
		local j = (i - 1) * 3 + 1
		local p     = hs[j]
		local idx   = hs[j + 1]
		local epoch = hs[j + 2]

		if p then
			p:_unsubscribe_at(idx, self, epoch)
		end

		hs[j], hs[j + 1], hs[j + 2] = nil, nil, nil
	end
	self.nh = 0
end

function WaitToken:_woken_by(_pulse, sched, epoch)
	local fib = self.fib

	-- Validate: this wake corresponds to the fibre's current wait.
	if fib._waiting_token ~= self or fib._waiting_epoch ~= epoch then
		return
	end

	-- Cancel remaining subscriptions from this wait epoch.
	self:_cancel_all()

	fib._waiting_token = nil
	fib._waiting_epoch = nil
	fib._waiting_waitable = nil

	sched:schedule(fib)
end

----------------------------------------------------------------------
-- Runtime API
----------------------------------------------------------------------

function runtime.scheduler()
	return runtime.sched
end

function runtime.current_fiber()
	return _current_fiber
end

function runtime.await(waitable)
	local fib = _current_fiber
	if not fib then error('await must be called from inside a fibre', 2) end
	if fib._waiting_token ~= nil then
		error('await called while already waiting', 2)
	end

	local tok   = fib._wait_token
	local epoch = tok:_begin_wait()

	fib._waiting_waitable = waitable
	fib._waiting_token    = tok
	fib._waiting_epoch    = epoch

	waitable:subscribe(tok, epoch)
	return coroutine.yield(WAIT)
end

----------------------------------------------------------------------
-- Fibre task
----------------------------------------------------------------------

local Fiber = {}
Fiber.__index = Fiber

function Fiber.new(fn, name)
	local f = setmetatable({
		co     = coroutine.create(fn),
		name   = name or '<fiber>',
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

	if not ok then
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

	if not next(runtime._live) then
		return 'done'
	end

	for fib in pairs(runtime._live) do
		if fib._waiting_token == nil then
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

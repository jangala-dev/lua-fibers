local sched_mod = require 'fibers.sched2'
local pulse_mod = require 'fibers.pulse2'
local Pulse     = pulse_mod.Pulse

local runtime = {}
runtime.sched = sched_mod.new()

local WAIT = {} -- unique sentinel

local _current_fiber = nil
runtime._live = {}

local function is_pulse(x)
	return type(x) == 'table' and getmetatable(x) == Pulse
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

-- Await a Pulse or a pulse-union table: { n = k, [1]=p1, ... }.
function runtime.await(wait)
	local fib = _current_fiber
	if not fib then error('await must be called from inside a fibre', 2) end
	if fib._waiting_epoch ~= nil then
		error('await called while already waiting', 2)
	end

	local epoch = fib:_begin_wait()
	fib._waiting_epoch = epoch

	if is_pulse(wait) then
		wait:subscribe_fibre(fib, epoch)
	else
		-- Treat as pulse union.
		local n = wait and (wait.n or #wait) or 0
		if n <= 0 then error('await: empty pulse union', 2) end
		for i = 1, n do
			local p = wait[i]
			if not is_pulse(p) then
				error('await: pulse union contains non-pulse', 2)
			end
			p:subscribe_fibre(fib, epoch)
		end
	end

	return coroutine.yield(WAIT)
end

----------------------------------------------------------------------
-- Fibre task
----------------------------------------------------------------------

local Fiber = {}
Fiber.__index = Fiber

function Fiber:_begin_wait()
	self._wait_epoch = self._wait_epoch + 1
	self._wait_nh = 0
	return self._wait_epoch
end

function Fiber:_add_handle(pulse, idx)
	local n       = self._wait_nh + 1
	self._wait_nh = n
	local hs      = self._wait_hs
	local j       = (n - 1) * 2 + 1
	hs[j]         = pulse
	hs[j + 1]     = idx
end

function Fiber:_cancel_all_wait_handles()
	local hs = self._wait_hs
	local ep = self._waiting_epoch
	for i = 1, self._wait_nh do
		local j   = (i - 1) * 2 + 1
		local p   = hs[j]
		local idx = hs[j + 1]

		if p then
			p:_unsubscribe_at(idx, self, ep)
		end

		hs[j], hs[j + 1] = nil, nil
	end
	self._wait_nh = 0
end

function Fiber:_woken_by(_, sched, epoch)
	-- Validate: this wake corresponds to the fibre's current wait.
	if self._waiting_epoch ~= epoch then
		return
	end

	-- Cancel remaining subscriptions from this wait epoch.
	self:_cancel_all_wait_handles()

	self._waiting_epoch = nil
	sched:schedule(self)
end

function Fiber.new(fn, name)
	local f = setmetatable({
		co      = coroutine.create(fn),
		name    = name or '<fiber>',
		_queued = false,

		_waiting_epoch = nil,

		_wait_epoch = 0,
		_wait_hs    = {}, -- pairs: [pulse, idx]
		_wait_nh    = 0,
	}, Fiber)
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

	-- Until you integrate pollers/timers, treat “no runnable work” as deadlock.
	for fib in pairs(runtime._live) do
		if fib._waiting_epoch == nil then
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

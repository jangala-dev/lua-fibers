-- tests/test_op2.lua
package.path = '../?.lua;' .. package.path

local function reload()
	for _, m in ipairs({
		'fibers.runtime2',
		'fibers.sched2',
		'fibers.pulse2',
		'fibers.op2',
	}) do
		package.loaded[m] = nil
	end
	return require 'fibers.runtime2', require 'fibers.pulse2', require 'fibers.op2'
end

local function assert_eq(a, b, msg)
	if a ~= b then
		error((msg or 'assert_eq failed') .. (': got ' .. tostring(a) .. ', want ' .. tostring(b)), 2)
	end
end

local function assert_true(x, msg)
	if not x then error(msg or 'assert_true failed', 2) end
end

----------------------------------------------------------------------
-- perform: blocks on preview waitable until preview returns offer+payload; commit returns payload.
----------------------------------------------------------------------

do
	local runtime, pulse, op2 = reload()

	local p = pulse.new(runtime.scheduler())
	local ready = false
	local committed = false
	local preview_calls = 0

	local prim = setmetatable({
		preview = function(self)
			preview_calls = preview_calls + 1
			if not ready then
				return p, nil, nil
			end
			return nil, self, { n = 2, 1, 2 }
		end,
		commit = function(self, offer)
			assert_eq(offer, self, 'commit offer mismatch')
			committed = true
			return nil, { n = 2, 1, 2 }
		end,
		abort = function() end,
	}, op2.Op)

	local a, b
	runtime.spawn(function()
		a, b = op2.perform(prim)
	end, 'perform')

	-- First step: should block and not commit.
	assert_eq(runtime.step(), 'ran')
	assert_eq(committed, false)
	assert_eq(preview_calls, 1)

	ready = true
	p:signal()
	runtime.main()

	assert_eq(committed, true)
	assert_eq(a, 1)
	assert_eq(b, 2)
end

----------------------------------------------------------------------
-- choice: selects first ready arm; aborts losers; calls _attach_select where present.
----------------------------------------------------------------------

do
	local runtime, pulse, op2 = reload()

	local p = pulse.new(runtime.scheduler())

	local a = setmetatable({
		sel = nil,
		_attach_select = function(self, sel) self.sel = sel end,
		aborted = 0,
		preview = function()
			-- Always pending.
			return p, nil, nil
		end,
		commit = function()
			error('a.commit should not run')
		end,
		abort = function(self)
			self.aborted = self.aborted + 1
		end,
	}, op2.Op)

	local b_commits = 0
	local b = setmetatable({
		sel = nil,
		_attach_select = function(self, sel) self.sel = sel end,
		aborted = 0,
		preview = function(self)
			return nil, self, { n = 1, 'ok' }
		end,
		commit = function(self, offer)
			assert_eq(offer, self, 'b.commit offer mismatch')
			b_commits = b_commits + 1
			return nil, { n = 1, 'ok' }
		end,
		abort = function(self)
			self.aborted = self.aborted + 1
		end,
	}, op2.Op)

	local out
	runtime.spawn(function()
		out = op2.perform(op2.choice(a, b))
	end, 'choice')

	runtime.main()

	assert_eq(out, 'ok')
	assert_eq(a.aborted, 1, 'losing arm must be aborted')
	assert_eq(b.aborted, 0, 'winning arm should not be aborted')
	assert_eq(b_commits, 1, 'winning arm must commit once')
	assert(a.sel and b.sel and a.sel == b.sel, 'choice should attach the same sel object to both arms')
end

----------------------------------------------------------------------
-- choice pending waitable: if all arms are pending with distinct pulses,
-- choice should await a derived "any" waitable; waking either pulse should resume.
----------------------------------------------------------------------

do
	local runtime, pulse, op2 = reload()

	local sched = runtime.scheduler()
	local p1 = pulse.new(sched)
	local p2 = pulse.new(sched)

	local r1, r2 = false, false

	local a = setmetatable({
		preview = function(self)
			if not r1 then return p1, nil, nil end
			return nil, self, { n = 1, 'A' }
		end,
		commit = function(self, offer)
			assert_eq(offer, self)
			return nil, { n = 1, 'A' }
		end,
		abort = function() end,
	}, op2.Op)

	local b = setmetatable({
		preview = function(self)
			if not r2 then return p2, nil, nil end
			return nil, self, { n = 1, 'B' }
		end,
		commit = function(self, offer)
			assert_eq(offer, self)
			return nil, { n = 1, 'B' }
		end,
		abort = function() end,
	}, op2.Op)

	local f
	local out
	f = runtime.spawn(function()
		out = op2.perform(op2.choice(a, b))
	end, 'choice_any_wait')

	-- Run once: should block on a derived any waitable
	assert_eq(runtime.step(), 'ran')
	assert_true(f._waiting_waitable ~= nil, 'fiber should be waiting')
	assert_eq(f._waiting_waitable.kind, 'any', 'should be waiting on a derived any waitable')

	-- The derived any should have subscribed the runtime token to both source pulses.
	assert_eq(p1.nwait, 1, 'p1 should have one waiter')
	assert_eq(p2.nwait, 1, 'p2 should have one waiter')

	-- Make B ready and signal p2; should wake and complete.
	r2 = true
	p2:signal()
	runtime.main()

	assert_eq(out, 'B')
	assert_eq(p1.nwait, 0, 'other subscription should have been cancelled on wake')
	assert_eq(p2.nwait, 0, 'p2 drained by signal')
end

----------------------------------------------------------------------
-- all: transactional preview; if any arm pending, roll back earlier reservations and wait;
-- later succeeds once all arms can preview in the same attempt.
--
-- all returns per-arm payload packs: (pack(resA...), pack(resB...), ...)
----------------------------------------------------------------------

do
	local runtime, pulse, op2 = reload()

	local a_abort, b_abort = 0, 0
	local a_commit, b_commit = 0, 0
	local a_res, b_res = false, false
	local b_ready = false

	local pB = pulse.new(runtime.scheduler())

	local a = setmetatable({
		preview = function(self)
			a_res = true
			return nil, self, { n = 1, 'A' }
		end,
		commit = function(self, offer)
			assert_eq(offer, self)
			a_commit = a_commit + 1
			return nil, { n = 1, 'A' }
		end,
		abort = function(self, offer)
			-- all may pass offer when rolling back prepared reservations
			if offer ~= nil then assert_eq(offer, self) end
			a_abort = a_abort + 1
			a_res = false
		end,
	}, op2.Op)

	local b = setmetatable({
		preview = function(self)
			if not b_ready then
				return pB, nil, nil
			end
			b_res = true
			return nil, self, { n = 1, 'B' }
		end,
		commit = function(self, offer)
			assert_eq(offer, self)
			b_commit = b_commit + 1
			return nil, { n = 1, 'B' }
		end,
		abort = function(self, offer)
			if offer ~= nil then assert_eq(offer, self) end
			b_abort = b_abort + 1
			b_res = false
		end,
	}, op2.Op)

	local ra, rb
	runtime.spawn(function()
		ra, rb = op2.perform(op2.all(a, b))
	end, 'all')

	-- First step: blocks (b pending). a's reservation must be rolled back.
	assert_eq(runtime.step(), 'ran')

	assert(a_abort > 0, 'prepared arm must be aborted when another arm is pending')
	assert_eq(a_res, false, 'arm A reservation should have been rolled back')
	assert_eq(ra, nil)
	assert_eq(rb, nil)

	-- Make b ready and signal the pending dependency.
	b_ready = true
	pB:signal()

	runtime.main()

	assert(type(ra) == 'table' and ra.n == 1 and ra[1] == 'A', 'unexpected result from arm A')
	assert(type(rb) == 'table' and rb.n == 1 and rb[1] == 'B', 'unexpected result from arm B')
	assert_eq(a_commit, 1)
	assert_eq(b_commit, 1)
	assert_eq(b_abort, 0, 'arm B should not be aborted in the successful run')
end

----------------------------------------------------------------------
-- wrap: applies to previewed payload and is consistent with committed results; composes in order.
----------------------------------------------------------------------

do
	local runtime, _pulse, op2 = reload()

	local committed = 0

	local prim = setmetatable({
		preview = function(self)
			return nil, self, { n = 1, 10 }
		end,
		commit = function(self, offer)
			assert_eq(offer, self)
			committed = committed + 1
			return nil, { n = 1, 10 }
		end,
		abort = function() end,
	}, op2.Op)

	local out
	runtime.spawn(function()
		out = op2.perform(prim
			:wrap(function(x) return x + 1 end)
			:wrap(function(x) return x * 2 end))
	end, 'wrap')

	runtime.main()

	assert_eq(out, 22, 'wrap composition mismatch')
	assert_eq(committed, 1, 'underlying op should commit once')
end

io.write('ok: op2 (preview/commit + targeted waiting)\n')

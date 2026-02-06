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

local function assert_false(x, msg)
	if x then error(msg or 'assert_false failed', 2) end
end

local function assert_err(f, pat, msg)
	local ok, e = pcall(f)
	if ok then error(msg or 'expected error, got success', 2) end
	if pat and not tostring(e):match(pat) then
		error((msg or 'error mismatch') .. (': got ' .. tostring(e)), 2)
	end
end

local function assert_waiting(fib, msg)
	assert_true(fib._waiting_epoch ~= nil, msg or 'fiber should be waiting')
end

----------------------------------------------------------------------
-- perform: blocks on preview pulse until preview returns offer+payload; commit returns payload.
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
			return { n = 2, 1, 2 }
		end,
		abort = function() end,
	}, op2.Op)

	local a, b
	local f = runtime.spawn(function()
		a, b = op2.perform(prim)
	end, 'perform')

	-- First step: should block and not commit.
	assert_eq(runtime.step(), 'ran')
	assert_eq(committed, false)
	assert_eq(preview_calls, 1)
	assert_waiting(f)

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
			return { n = 1, 'ok' }
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
	assert_true(a.sel and b.sel and a.sel == b.sel, 'choice should attach the same sel object to both arms')
end

----------------------------------------------------------------------
-- choice pending: if all arms are pending with distinct pulses, waiting subscribes to both;
-- waking either pulse should resume, and the wake should cancel other subscriptions.
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
			return { n = 1, 'A' }
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
			return { n = 1, 'B' }
		end,
		abort = function() end,
	}, op2.Op)

	local f
	local out
	f = runtime.spawn(function()
		out = op2.perform(op2.choice(a, b))
	end, 'choice_union_wait')

	-- Run once: should block and subscribe to both pulses.
	assert_eq(runtime.step(), 'ran')
	assert_waiting(f)
	assert_true(p1:has_waiters(), 'p1 should have waiters')
	assert_true(p2:has_waiters(), 'p2 should have waiters')

	-- Make B ready and signal p2; should wake and complete.
	r2 = true
	p2:signal()
	runtime.main()

	assert_eq(out, 'B')
	assert_false(p1:has_waiters(), 'other subscription should have been cancelled on wake')
	assert_false(p2:has_waiters(), 'p2 drained by signal')
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
	local a_res = false
	local b_res = false
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
			return { n = 1, 'A' }
		end,
		abort = function(self, offer)
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
			return { n = 1, 'B' }
		end,
		abort = function(self, offer)
			if offer ~= nil then assert_eq(offer, self) end
			b_abort = b_abort + 1
			b_res = false
		end,
	}, op2.Op)

	local ra, rb
	local f = runtime.spawn(function()
		ra, rb = op2.perform(op2.all(a, b))
	end, 'all')

	assert_eq(runtime.step(), 'ran')
	assert_waiting(f)
	assert_true(a_abort > 0, 'prepared arm must be aborted when another arm is pending')
	assert_eq(a_res, false, 'arm A reservation should have been rolled back')
	assert_eq(ra, nil)
	assert_eq(rb, nil)

	b_ready = true
	pB:signal()
	runtime.main()

	assert_true(type(ra) == 'table' and ra.n == 1 and ra[1] == 'A', 'unexpected result from arm A')
	assert_true(type(rb) == 'table' and rb.n == 1 and rb[1] == 'B', 'unexpected result from arm B')
	assert_eq(a_commit, 1)
	assert_eq(b_commit, 1)
	assert_eq(b_abort, 0, 'arm B should not be aborted in the successful run')
	assert_eq(b_res, true)
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
			return { n = 1, 10 }
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

----------------------------------------------------------------------
-- and_then: forwards all LHS values to k(...), returns RHS values only;
-- commits LHS then RHS (in that order).
----------------------------------------------------------------------

do
	local runtime, _pulse, op2 = reload()

	local log = {}
	local lhs_commit = 0
	local rhs_commit = 0
	local k_calls = 0

	local lhs = setmetatable({
		offer = 1,
		preview = function(self)
			return nil, self.offer, { n = 3, 'x', 'y', 'z' }
		end,
		commit = function(self, offer)
			assert_eq(offer, self.offer, 'lhs.commit offer mismatch')
			lhs_commit = lhs_commit + 1
			log[#log + 1] = 'lhs'
			return op2.EMPTY
		end,
		abort = function() end,
	}, op2.Op)

	local function k(a, b, c)
		k_calls = k_calls + 1
		assert_eq(a, 'x'); assert_eq(b, 'y'); assert_eq(c, 'z')

		local rhs = setmetatable({
			offer = 7,
			preview = function(self)
				return nil, self.offer, { n = 1, 'R' }
			end,
			commit = function(self, offer)
				assert_eq(offer, self.offer, 'rhs.commit offer mismatch')
				rhs_commit = rhs_commit + 1
				log[#log + 1] = 'rhs'
				return { n = 1, 'R' }
			end,
			abort = function() end,
		}, op2.Op)

		return rhs
	end

	local out
	runtime.spawn(function()
		out = op2.perform(lhs:and_then(k))
	end, 'and_then_basic')

	runtime.main()

	assert_eq(out, 'R')
	assert_eq(k_calls, 1)
	assert_eq(lhs_commit, 1)
	assert_eq(rhs_commit, 1)
	assert_eq(log[1], 'lhs')
	assert_eq(log[2], 'rhs')
end

----------------------------------------------------------------------
-- and_then pending RHS:
-- If RHS is pending, it must abort RHS and abort LHS (do not hold reservation),
-- then await (rhs_wait OR lhs:watch(offer)) when watch is provided.
----------------------------------------------------------------------

do
	local runtime, pulse, op2 = reload()

	local sched = runtime.scheduler()
	local p_rhs   = pulse.new(sched)
	local p_watch = pulse.new(sched)

	local rhs_ready = false

	local lhs_reserved = false
	local lhs_abort = 0

	local lhs = setmetatable({
		offer = 1,
		preview = function(self)
			lhs_reserved = true
			return nil, self.offer, { n = 1, 'L' }
		end,
		watch = function(_self, _offer)
			return p_watch
		end,
		commit = function(self, offer)
			assert_eq(offer, self.offer)
			lhs_reserved = false
			return op2.EMPTY
		end,
		abort = function(self, offer)
			if offer ~= nil then assert_eq(offer, self.offer) end
			lhs_reserved = false
			lhs_abort = lhs_abort + 1
		end,
	}, op2.Op)

	local rhs_abort = 0
	local function k(_lval)
		return setmetatable({
			offer = 2,
			preview = function(self)
				if not rhs_ready then
					return p_rhs, nil, nil
				end
				return nil, self.offer, { n = 1, 'OK' }
			end,
			commit = function(self, offer)
				assert_eq(offer, self.offer)
				return { n = 1, 'OK' }
			end,
			abort = function()
				rhs_abort = rhs_abort + 1
			end,
		}, op2.Op)
	end

	local f
	local out
	f = runtime.spawn(function()
		out = op2.perform(lhs:and_then(k))
	end, 'and_then_pending_union')

	-- First step: should block and subscribe to both pulses.
	assert_eq(runtime.step(), 'ran')
	assert_waiting(f)

	assert_true(p_rhs:has_waiters(), 'rhs pulse should have waiters')
	assert_true(p_watch:has_waiters(), 'lhs watch pulse should have waiters')

	-- LHS reservation must not be held.
	assert_true(lhs_abort > 0, 'lhs should have been aborted when rhs is pending')
	assert_eq(lhs_reserved, false, 'lhs reservation should not be held across waits')

	-- Now make RHS ready and signal it.
	rhs_ready = true
	p_rhs:signal()
	runtime.main()

	assert_eq(out, 'OK')
	assert_true(not p_watch:has_waiters(), 'lhs watch subscription should have been cancelled on wake')
end

----------------------------------------------------------------------
-- nested choice: if a later arm is ready, it wins; loser aborts must propagate cleanly.
----------------------------------------------------------------------

do
	local runtime, pulse, op2 = reload()

	local sched = runtime.scheduler()
	local p_rhs   = pulse.new(sched)
	local p_watch = pulse.new(sched)

	local lhs_abort = 0
	local lhs_reserved = false

	local lhs = setmetatable({
		offer = 1,
		preview = function(self)
			lhs_reserved = true
			return nil, self.offer, { n = 1, 'L' }
		end,
		watch = function()
			return p_watch
		end,
		commit = function()
			error('lhs.commit should not run (losing and_then)')
		end,
		abort = function()
			lhs_reserved = false
			lhs_abort = lhs_abort + 1
		end,
	}, op2.Op)

	local function k(_)
		return setmetatable({
			preview = function()
				return p_rhs, nil, nil -- always pending
			end,
			commit = function()
				error('rhs.commit should not run (losing and_then)')
			end,
			abort = function() end,
		}, op2.Op)
	end

	local pending_arm = lhs:and_then(k)

	local ready_commits = 0
	local ready_arm = setmetatable({
		preview = function(self) return nil, self, { n = 1, 'WIN' } end,
		commit  = function(self, offer)
			assert_eq(offer, self)
			ready_commits = ready_commits + 1
			return { n = 1, 'WIN' }
		end,
		abort = function() end,
	}, op2.Op)

	local out
	runtime.spawn(function()
		out = op2.perform(op2.choice(pending_arm, ready_arm))
	end, 'nested_choice_ready_wins')

	runtime.main()

	assert_eq(out, 'WIN')
	assert_eq(ready_commits, 1)
	assert_true(lhs_abort >= 1, 'losing and_then should abort its lhs')
	assert_eq(lhs_reserved, false, 'losing and_then should not leave lhs reserved')
end

----------------------------------------------------------------------
-- nested choice pending: outer choice should subscribe to source pulses via pulse unions.
----------------------------------------------------------------------

do
	local runtime, pulse, op2 = reload()

	local sched = runtime.scheduler()
	local p1 = pulse.new(sched)
	local p2 = pulse.new(sched)
	local p3 = pulse.new(sched)

	local r2 = false

	local a = setmetatable({
		preview = function() return p1, nil, nil end,
		commit  = function() error('a.commit should not run') end,
		abort   = function() end,
	}, op2.Op)

	local b = setmetatable({
		preview = function(self)
			if not r2 then return p2, nil, nil end
			return nil, self, { n = 1, 'B' }
		end,
		commit = function(self, offer)
			assert_eq(offer, self)
			return { n = 1, 'B' }
		end,
		abort = function() end,
	}, op2.Op)

	local c = setmetatable({
		preview = function() return p3, nil, nil end,
		commit  = function() error('c.commit should not run') end,
		abort   = function() end,
	}, op2.Op)

	local inner = op2.choice(a, b)
	local outer = op2.choice(inner, c)

	local f
	local out
	f = runtime.spawn(function()
		out = op2.perform(outer)
	end, 'nested_choice_union')

	-- First step should block and subscribe to p1, p2, p3.
	assert_eq(runtime.step(), 'ran')
	assert_waiting(f)

	assert_true(p1:has_waiters(), 'p1 should have waiters')
	assert_true(p2:has_waiters(), 'p2 should have waiters')
	assert_true(p3:has_waiters(), 'p3 should have waiters')

	-- Make b ready and wake via p2.
	r2 = true
	p2:signal()
	runtime.main()

	assert_eq(out, 'B')

	-- All subscriptions should be gone after a valid wake+completion.
	assert_true(not p1:has_waiters(), 'p1 should have no waiters')
	assert_true(not p2:has_waiters(), 'p2 should have no waiters')
	assert_true(not p3:has_waiters(), 'p3 should have no waiters')
end

----------------------------------------------------------------------
-- watch: default is nil; wrap delegates to inner watch.
----------------------------------------------------------------------

do
	local runtime, pulse, op2 = reload()

	local p = pulse.new(runtime.scheduler())
	local prim = setmetatable({
		preview = function(self) return nil, self, { n = 1, 1 } end,
		commit = function(self, offer) assert_eq(offer, self); return { n = 1, 1 } end,
		abort = function() end,
		watch = function(self, offer) assert_eq(offer, self); return p end,
	}, op2.Op)

	assert_eq(prim:watch(prim), p)
	assert_eq(prim:wrap(function(x) return x end):watch(prim), p)
end

----------------------------------------------------------------------
-- and_then offer churn:
-- If RHS is pending for the current LHS offer, and LHS later changes (signals its watchable),
-- and_then must wake, re-preview LHS, re-run k(...) for the new LHS payload, and complete.
----------------------------------------------------------------------

do
	local runtime, pulse, op2 = reload()

	local sched = runtime.scheduler()
	local pL = pulse.new(sched) -- lhs watchable / invalidation pulse
	local pR = pulse.new(sched) -- rhs pending pulse (we will not signal this)

	local lhs_abort = 0
	local rhs_abort = 0
	local k_calls   = 0

	local lhs_val = 'A'

	local lhs = setmetatable({
		preview = function(self)
			return nil, lhs_val, { n = 1, lhs_val }
		end,
		commit = function(self, offer)
			assert_eq(offer, lhs_val)
			return op2.EMPTY
		end,
		abort = function(self, _offer)
			lhs_abort = lhs_abort + 1
		end,
		watch = function(self, offer)
			assert_eq(offer, lhs_val)
			return pL
		end,
	}, op2.Op)

	local function mk_rhs_for(x)
		return setmetatable({
			preview = function(self)
				if x == 'A' then
					return pR, nil, nil
				end
				return nil, 1, { n = 1, 'OK_' .. x }
			end,
			commit = function(self, offer)
				assert_eq(offer, 1)
				return { n = 1, 'OK_' .. x }
			end,
			abort = function(self, _offer)
				rhs_abort = rhs_abort + 1
			end,
		}, op2.Op)
	end

	local function k(x)
		k_calls = k_calls + 1
		return mk_rhs_for(x)
	end

	local f
	local out
	f = runtime.spawn(function()
		out = op2.perform(lhs:and_then(k))
	end, 'and_then_offer_churn')

	-- First step: LHS ready with 'A', RHS pending => should await (pR OR pL)
	assert_eq(runtime.step(), 'ran')
	assert_waiting(f)

	assert_true(pL:has_waiters(), 'lhs watch pulse should have waiters')
	assert_true(pR:has_waiters(), 'rhs wait pulse should have waiters')
	assert_eq(k_calls, 1, 'k should have been called once for initial LHS payload')
	assert_true(lhs_abort > 0, 'lhs should have been aborted when rhs was pending (no reservation held)')

	-- Change LHS only and signal its watchable; do not signal pR.
	lhs_val = 'B'
	pL:signal()
	runtime.main()

	assert_eq(out, 'OK_B', 'and_then should re-derive RHS from updated LHS payload')
	assert_true(k_calls >= 2, 'k should be re-run when LHS payload changes')
	assert_true(rhs_abort > 0, 'pending RHS for previous LHS payload should have been aborted')
	assert_true(not pL:has_waiters(), 'subscriptions should be cancelled on wake')
	assert_true(not pR:has_waiters(), 'rhs subscription should have been cancelled on wake')
end

io.write('ok: op2\n')

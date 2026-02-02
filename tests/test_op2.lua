-- tests/test_op2.lua
--
-- Synthetic tests for fibers/op2.lua (fixed-arity internal protocol).
--
-- Assumptions:
--   * fibers.runtime provides a global scheduler and cooperative fibres.
--   * fibers.op2 is the module under test.
--
-- How to run (example):
--   lua tests/test_op2.lua

package.path = '../src/?.lua;' .. package.path

local runtime = require 'fibers.runtime'
local op2     = require 'fibers.op2'
local safe    = require 'coxpcall'

local unpack = rawget(table, 'unpack') or _G.unpack
local pack   = rawget(table, 'pack') or function (...) return { n = select('#', ...), ... } end

----------------------------------------------------------------------
-- Minimal assertions
----------------------------------------------------------------------

local function fail(msg, lvl)
	error(msg or 'test failed', (lvl or 1) + 1)
end

local function assert_true(x, msg)
	if not x then fail(msg or 'expected true', 1) end
end

local function assert_false(x, msg)
	if x then fail(msg or 'expected false', 1) end
end

local function assert_eq(a, b, msg)
	if a ~= b then
		fail((msg or 'values not equal') .. (': got ' .. tostring(a) .. ', expected ' .. tostring(b)), 1)
	end
end

local function assert_tbl(t, msg)
	if type(t) ~= 'table' then fail(msg or 'expected table', 1) end
end

local function assert_pack_eq(p, expected)
	assert_tbl(p, 'expected pack table')
	assert_eq(p.n, #expected, 'pack length mismatch')
	for i = 1, #expected do
		assert_eq(p[i], expected[i], 'pack element mismatch at ' .. i)
	end
end

----------------------------------------------------------------------
-- Scheduler helpers
----------------------------------------------------------------------

local function mk_task(fn)
	local t = {}
	function t:run() fn() end
	return t
end

local function schedule(fn)
	runtime.current_scheduler:schedule(mk_task(fn))
end

-- Cooperative “tick”: allow other scheduled tasks to run.
local function tick()
	runtime.yield()
end

----------------------------------------------------------------------
-- Tags (integers)
----------------------------------------------------------------------

local TAG_PENDING   = op2.TAG_PENDING
local TAG_PREVIEW   = op2.TAG_PREVIEW
local TAG_DONE      = op2.TAG_DONE
local TAG_CANCELLED = op2.TAG_CANCELLED

----------------------------------------------------------------------
-- Synthetic tickets and primitives (fixed-arity internal protocol)
----------------------------------------------------------------------

-- Manual, event-driven ticket you can mutate from scheduled tasks.
--
-- preview(ctx) -> tag, proposal, payload_pack, pulse
--   pending   -> TAG_PENDING, nil, nil, pulse
--   preview   -> TAG_PREVIEW, proposal, payload_pack, pulse
--   cancelled -> TAG_CANCELLED, nil, nil, nil
--
-- commit(ctx) -> tag, proposal, payload_pack, pulse
--   aborted        -> TAG_CANCELLED
--   not committing -> TAG_CANCELLED
--   committing     -> if not preview => TAG_CANCELLED
--                    else if commit_latched and not allowed => TAG_PENDING, pulse
--                    else => TAG_DONE, proposal_or_override, payload_pack
local function make_manual_ticket(opts)
	opts = opts or {}

	local p = op2.new_pulse()
	local state = opts.initial or 'pending'

	local proposal = opts.proposal or {}
	local values   = opts.values and pack(unpack(opts.values, 1, opts.values.n or #opts.values)) or pack()

	local cancels = 0
	local post_abort = 0

	local commit_latched = not not opts.commit_latched
	local commit_allowed = not commit_latched

	local commit_proposal_override = opts.commit_proposal_override -- function(ctx, current_proposal) -> proposal

	local ticket = {}

	function ticket:pulse()
		return p
	end

	function ticket:preview(_ctx)
		if state == 'cancelled' then
			return TAG_CANCELLED, nil, nil, nil
		elseif state == 'pending' then
			return TAG_PENDING, nil, nil, p
		elseif state == 'preview' then
			return TAG_PREVIEW, proposal, values, p
		else
			error('manual_ticket: invalid state ' .. tostring(state), 0)
		end
	end

	function ticket:commit(ctx)
		if ctx.gate_state == op2.GATE_ABORTED then
			return TAG_CANCELLED, nil, nil, nil
		end
		if ctx.gate_state ~= op2.GATE_COMMITTING then
			return TAG_CANCELLED, nil, nil, nil
		end

		if state ~= 'preview' then
			return TAG_CANCELLED, nil, nil, nil
		end

		if commit_latched and not commit_allowed then
			return TAG_PENDING, nil, nil, p
		end

		local cp = proposal
		if commit_proposal_override then
			cp = commit_proposal_override(ctx, proposal)
		end

		return TAG_DONE, cp, values, nil
	end

	function ticket:cancel(_ctx)
		cancels = cancels + 1
		state = 'cancelled'
		p:signal()
	end

	function ticket:_post_commit_abort(_ctx)
		post_abort = post_abort + 1
	end

	local ctl = {}

	function ctl:set_pending()
		state = 'pending'
		p:signal()
	end

	function ctl:set_preview(new_proposal, ...)
		state = 'preview'
		proposal = new_proposal or {}
		values = pack(...)
		p:signal()
	end

	function ctl:set_cancelled()
		state = 'cancelled'
		p:signal()
	end

	function ctl:allow_commit()
		commit_allowed = true
	end

	function ctl:signal()
		p:signal()
	end

	function ctl:cancels() return cancels end
	function ctl:post_abort_calls() return post_abort end
	function ctl:pulse() return p end
	function ctl:proposal() return proposal end

	return ticket, ctl
end

local function prim_from_ticket(ticket)
	return op2.new_primitive(function (_ctx)
		return ticket
	end)
end

-- A primitive op that is preview-ready immediately, but commit stays pending
-- until a flag is set. Crucially: it does NOT signal its pulse when the flag flips.
-- This validates the “yield once” path in perform().
local function make_yield_latch_primitive(value)
	local pulse = op2.new_pulse()
	local proposal = {}
	local can_commit = false

	local payload = pack(value)

	local ticket = {}

	function ticket:pulse() return pulse end

	function ticket:preview(_ctx)
		return TAG_PREVIEW, proposal, payload, pulse
	end

	function ticket:commit(ctx)
		if ctx.gate_state == op2.GATE_ABORTED then return TAG_CANCELLED, nil, nil, nil end
		if ctx.gate_state ~= op2.GATE_COMMITTING then return TAG_CANCELLED, nil, nil, nil end
		if not can_commit then
			return TAG_PENDING, nil, nil, pulse
		end
		return TAG_DONE, proposal, payload, nil
	end

	function ticket:cancel(_ctx)
		-- no-op
	end

	local op = prim_from_ticket(ticket)

	local ctl = {}
	function ctl:allow_commit() can_commit = true end

	return op, ctl
end

----------------------------------------------------------------------
-- Test registration
----------------------------------------------------------------------

local tests = {}

local function test(name, fn)
	tests[#tests + 1] = { name = name, fn = fn }
end

----------------------------------------------------------------------
-- Tests
----------------------------------------------------------------------

test('pulse subscribe_node schedules task once epoch advances', function ()
	local pulse = op2.new_pulse()
	local ran = 0

	local task = {}
	function task:run()
		ran = ran + 1
	end

	-- Intrusive node supplied by the caller; task/waker are stable and set once.
	local node = {
		_pulse  = nil, _prev = nil, _next = nil, _linked = false,
		_task   = task,
		_waker  = runtime.current_scheduler,
	}

	-- Subscribe at current epoch; task should not run until we signal.
	local linked = pulse:subscribe_node(pulse:now(), node)
	assert_true(linked, 'expected node to be linked')

	-- Signal and yield so scheduled task runs.
	pulse:signal()
	tick()
	assert_eq(ran, 1, 'expected task to run after signal')

	-- Node should have been detached by the pulse one-shot.
	assert_false(node._linked, 'expected node to be unlinked after signal')
	assert_eq(node._pulse, nil, 'expected node pulse cleared')

	-- If subscribing with a stale epoch, it should schedule immediately (no link).
	local linked2 = pulse:subscribe_node(pulse:now() - 1, node)
	assert_false(linked2, 'expected immediate scheduling when epoch already advanced')
	tick()
	assert_eq(ran, 2, 'expected task to run after immediate schedule')
end)

test('choice(always, never) returns always result', function ()
	local v = op2.perform(op2.choice(op2.always('ok'), op2.never()))
	assert_eq(v, 'ok')
end)

test('wrap applied once per attempt; preview/commit caching prevents double-application', function ()
	local calls = 0
	local function f(x)
		calls = calls + 1
		return x * 2
	end

	local v = op2.perform(op2.always(21):wrap(f))
	assert_eq(v, 42)
	assert_eq(calls, 1, 'wrap should run once (cached across commit)')

	local v2 = op2.perform(op2.always(5):wrap(f))
	assert_eq(v2, 10)
	assert_eq(calls, 2, 'wrap should run once per perform() call')
end)

test('wrap propagates errors from f()', function ()
	local function boom()
		error('boom', 0)
	end

	local ok, err = pcall(function ()
		op2.perform(op2.always('x'):wrap(boom))
	end)

	assert_false(ok, 'expected wrapped perform to error')
	assert_true(tostring(err):match('boom') ~= nil, 'expected boom in error message')
end)

test('finally runs cleanup(false) on success', function ()
	local seen = {}
	local op = op2.always(1):finally(function (aborted)
		seen[#seen + 1] = aborted
	end)

	local v = op2.perform(op)
	assert_eq(v, 1)
	assert_eq(#seen, 1)
	assert_eq(seen[1], false)
end)

test('choice losers receive post-commit abort; finally(true) and on_abort() run best-effort', function ()
	local fin_aborted = nil
	local abort_calls = 0

	local loser =
		op2.always('loser')
			:finally(function (aborted) fin_aborted = aborted end)
			:on_abort(function () abort_calls = abort_calls + 1 end)

	local winner = op2.always('winner')

	local v = op2.perform(op2.choice(winner, loser))
	assert_eq(v, 'winner')

	assert_eq(fin_aborted, true, 'loser finally should run with aborted=true after winner commits')
	assert_eq(abort_calls, 1, 'loser abort handler should run once')
end)

test('perform yields once on first commit pending (enables progress without pulse signalling)', function ()
	local op, ctl = make_yield_latch_primitive('ok')

	-- Allow commit via a scheduled task, but do not signal the op’s pulse.
	-- If perform did not yield once, this would deadlock (pending pulse never signals).
	schedule(function ()
		ctl:allow_commit()
	end)

	local v = op2.perform(op)
	assert_eq(v, 'ok')
end)

test('choice retries when winner proposal changes between preview and commit', function ()
	local attempts = 0

	local flaky = op2.new_primitive(function (_ctx)
		attempts = attempts + 1
		local pulse = op2.new_pulse()

		local p_preview = {}
		local p_commit  = (attempts == 1) and {} or p_preview

		local payload = pack('value')

		local ticket = {}

		function ticket:pulse() return pulse end
		function ticket:preview(_ctx2)
			return TAG_PREVIEW, p_preview, payload, pulse
		end
		function ticket:commit(ctx2)
			if ctx2.gate_state == op2.GATE_ABORTED then return TAG_CANCELLED, nil, nil, nil end
			if ctx2.gate_state ~= op2.GATE_COMMITTING then return TAG_CANCELLED, nil, nil, nil end
			return TAG_DONE, p_commit, payload, nil
		end
		function ticket:cancel(_ctx2) end

		return ticket
	end)

	local v = op2.perform(op2.choice(flaky, op2.never()))
	assert_eq(v, 'value')
	assert_eq(attempts, 2, 'expected one retry due to proposal mismatch')
end)

test('all(...) returns table of packed child values on success', function ()
	local res = op2.perform(op2.all(op2.always(1), op2.always(2)))
	assert_tbl(res, 'expected all() to return a results table')

	assert_tbl(res[1], 'expected packed entry for child 1')
	assert_tbl(res[2], 'expected packed entry for child 2')

	assert_pack_eq(res[1], { 1 })
	assert_pack_eq(res[2], { 2 })
end)

test('all retries when a child commit proposal does not match prepared proposal', function ()
	local attempts = 0

	local child = op2.new_primitive(function (_ctx)
		attempts = attempts + 1
		local pulse = op2.new_pulse()
		local p_preview = {}
		local p_commit  = (attempts == 1) and {} or p_preview

		local payload = pack('x')

		local ticket = {}

		function ticket:pulse() return pulse end
		function ticket:preview(_ctx2)
			return TAG_PREVIEW, p_preview, payload, pulse
		end
		function ticket:commit(ctx2)
			if ctx2.gate_state == op2.GATE_ABORTED then return TAG_CANCELLED, nil, nil, nil end
			if ctx2.gate_state ~= op2.GATE_COMMITTING then return TAG_CANCELLED, nil, nil, nil end
			return TAG_DONE, p_commit, payload, nil
		end
		function ticket:cancel(_ctx2) end

		return ticket
	end)

	local res = op2.perform(op2.all(child, op2.always('y')))
	assert_eq(attempts, 2, 'expected retry due to proposal mismatch in all()')
	assert_pack_eq(res[1], { 'x' })
	assert_pack_eq(res[2], { 'y' })
end)

test('and_then rebuilds RHS when LHS proposal changes (ticket-level)', function ()
	-- LHS is a manual ticket controlled by the test.
	local left_ticket, left_ctl = make_manual_ticket({ initial = 'pending' })
	local left_op = prim_from_ticket(left_ticket)

	-- RHS: build a fresh primitive per LHS value; track cancellations of prior RHS instances.
	local rhs_cancelled = 0

	local function rhs_for(x)
		return op2.new_primitive(function (_ctx)
			local pulse = op2.new_pulse()
			local prop  = {}
			local payload = pack(x * 10)

			local ticket = {}

			function ticket:pulse() return pulse end
			function ticket:preview(_ctx2) return TAG_PREVIEW, prop, payload, pulse end
			function ticket:commit(ctx2)
				if ctx2.gate_state == op2.GATE_ABORTED then return TAG_CANCELLED, nil, nil, nil end
				if ctx2.gate_state ~= op2.GATE_COMMITTING then return TAG_CANCELLED, nil, nil, nil end
				return TAG_DONE, prop, payload, nil
			end
			function ticket:cancel(_ctx2) rhs_cancelled = rhs_cancelled + 1 end

			return ticket
		end)
	end

	local op = left_op:and_then(function (x)
		return rhs_for(x)
	end)

	-- Instantiate ticket graph so we can call preview repeatedly with gate open.
	local scheduler = runtime.current_scheduler
	local ctx = {
		gate_state = op2.GATE_OPEN,
		scheduler  = scheduler,

		-- not used by this test (no blocking), but harmless to provide.
		_wait_node = { _linked = false, _task = runtime.current_fiber(), _waker = scheduler },
	}
	local root = op:_instantiate(ctx)

	-- First: drive LHS to preview(1).
	left_ctl:set_preview({}, 1)

	local tag, _prop, payload = root:preview(ctx)
	assert_eq(tag, TAG_PREVIEW)
	assert_tbl(payload, 'expected payload pack')
	assert_eq(payload[1], 10)

	-- Change LHS proposal/value; RHS should be invalidated and rebuilt.
	left_ctl:set_preview({}, 2)

	local tag2, _prop2, payload2 = root:preview(ctx)
	assert_eq(tag2, TAG_PREVIEW)
	assert_tbl(payload2, 'expected payload pack')
	assert_eq(payload2[1], 20)

	assert_true(rhs_cancelled >= 1, 'expected old RHS instance to be cancelled on LHS proposal change')
end)

test('bracket releases on cancelled attempt (aborted=true) and on success (aborted=false)', function ()
	local acquired = 0
	local releases = {} -- { { aborted = bool, res = any }, ... }

	local function acquire()
		acquired = acquired + 1
		return { id = acquired }
	end

	local function release(res, aborted)
		releases[#releases + 1] = { res = res, aborted = aborted }
	end

	-- Inner op: first attempt cancels in preview, second attempt succeeds.
	local attempts = 0
	local inner = op2.new_primitive(function (_ctx)
		attempts = attempts + 1
		local pulse = op2.new_pulse()
		local prop  = {}
		local payload = pack('ok')

		local ticket = {}

		function ticket:pulse() return pulse end

		function ticket:preview(_ctx2)
			if attempts == 1 then return TAG_CANCELLED, nil, nil, nil end
			return TAG_PREVIEW, prop, payload, pulse
		end

		function ticket:commit(ctx2)
			if ctx2.gate_state == op2.GATE_ABORTED then return TAG_CANCELLED, nil, nil, nil end
			if ctx2.gate_state ~= op2.GATE_COMMITTING then return TAG_CANCELLED, nil, nil, nil end
			return TAG_DONE, prop, payload, nil
		end

		function ticket:cancel(_ctx2) end

		return ticket
	end)

	local op = op2.bracket(acquire, release, function (_res)
		return inner
	end)

	local v = op2.perform(op)
	assert_eq(v, 'ok')

	assert_eq(attempts, 2, 'expected retry after preview cancellation')
	assert_eq(acquired, 2, 'expected acquire per attempt')

	-- We expect two releases: first aborted=true (cancelled attempt), then aborted=false (success).
	assert_eq(#releases, 2, 'expected one release per attempt')
	assert_eq(releases[1].aborted, true)
	assert_eq(releases[2].aborted, false)
end)

----------------------------------------------------------------------
-- Runner
----------------------------------------------------------------------

local function run_all()
	local passed, failed = 0, 0

	for i = 1, #tests do
		local t = tests[i]
		local ok, err = safe.pcall(t.fn)
		if ok then
			passed = passed + 1
			io.write('ok - ' .. t.name .. '\n')
		else
			failed = failed + 1
			io.write('not ok - ' .. t.name .. '\n')
			io.write('  ' .. tostring(err) .. '\n')
		end

		-- Give the scheduler a chance to run any straggler tasks between tests.
		tick()
	end

	io.write(('\nSummary: %d passed, %d failed\n'):format(passed, failed))

	if failed > 0 then
		error(('test run failed (%d failed)'):format(failed), 0)
	end
end

runtime.spawn_raw(function (_wrap)
	run_all()
	runtime.stop()
end)

runtime.main()

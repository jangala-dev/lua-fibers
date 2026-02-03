-- tests/test_op2.lua
--
-- Synthetic tests for fibers/op2.lua (transactional preview/commit protocol).
--
-- How to run:
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

local function tick()
	runtime.yield()
end

----------------------------------------------------------------------
-- Tags
----------------------------------------------------------------------

local TAG_PENDING   = op2.TAG_PENDING
local TAG_PREVIEW   = op2.TAG_PREVIEW
local TAG_DONE      = op2.TAG_DONE
local TAG_CANCELLED = op2.TAG_CANCELLED

----------------------------------------------------------------------
-- Ticket helpers (metatable-style)
----------------------------------------------------------------------

local function ticket_class(proto)
	proto.__index = proto
	return proto
end

local function ticket_new(proto, fields)
	return setmetatable(fields, proto)
end

----------------------------------------------------------------------
-- Synthetic tickets and primitives
----------------------------------------------------------------------

local ManualTicket = ticket_class({})

function ManualTicket:pulse()
	return self._pulse
end

function ManualTicket:preview(_ctx)
	local state = self._state
	if state == 'cancelled' then
		return TAG_CANCELLED, nil, nil, nil
	elseif state == 'pending' then
		return TAG_PENDING, nil, nil, self._pulse
	elseif state == 'preview' then
		return TAG_PREVIEW, self._proposal, self._values, self._pulse
	end
	error('manual_ticket: invalid state ' .. tostring(state), 0)
end

function ManualTicket:commit(ctx, expected_proposal)
	if ctx.gate_state == op2.GATE_ABORTED then
		return TAG_CANCELLED, nil, nil
	end
	if ctx.gate_state ~= op2.GATE_COMMITTING then
		return TAG_CANCELLED, nil, nil
	end

	if self._state ~= 'preview' then
		return TAG_PENDING, nil, self._pulse
	end
	if expected_proposal ~= self._proposal then
		return TAG_PENDING, nil, self._pulse
	end
	if self._commit_latched and not self._commit_allowed then
		return TAG_PENDING, nil, self._pulse
	end

	return TAG_DONE, self._values, nil
end

function ManualTicket:cancel(_ctx)
	self._cancels = self._cancels + 1
	self._state = 'cancelled'
	self._pulse:signal()
end

function ManualTicket:_post_commit_abort(_ctx)
	self._post_abort = self._post_abort + 1
end

local function make_manual_ticket(opts)
	opts = opts or {}

	local pulse = op2.new_pulse()
	local proposal = opts.proposal or {}
	local values = opts.values and pack(unpack(opts.values, 1, opts.values.n or #opts.values)) or pack()

	local commit_latched = not not opts.commit_latched
	local commit_allowed = not commit_latched

	local inst = ticket_new(ManualTicket, {
		_pulse          = pulse,
		_state          = opts.initial or 'pending',
		_proposal       = proposal,
		_values         = values,
		_commit_latched = commit_latched,
		_commit_allowed = commit_allowed,
		_cancels        = 0,
		_post_abort     = 0,
	})

	local ctl = {}

	function ctl:set_pending()
		inst._state = 'pending'
		pulse:signal()
	end

	function ctl:set_preview(new_proposal, ...)
		inst._state = 'preview'
		inst._proposal = new_proposal or {}
		inst._values = pack(...)
		pulse:signal()
	end

	function ctl:set_cancelled()
		inst._state = 'cancelled'
		pulse:signal()
	end

	function ctl:allow_commit()
		inst._commit_allowed = true
		pulse:signal()
	end

	function ctl:signal()
		pulse:signal()
	end

	function ctl:cancels() return inst._cancels end
	function ctl:post_abort_calls() return inst._post_abort end
	function ctl:pulse() return pulse end
	function ctl:proposal() return inst._proposal end

	return inst, ctl
end

local function prim_from_ticket(ticket)
	return op2.new_primitive(function (_ctx)
		return ticket
	end)
end

local CommitLatchTicket = ticket_class({})

function CommitLatchTicket:pulse() return self._pulse end
function CommitLatchTicket:preview(_ctx) return TAG_PREVIEW, self._proposal, self._payload, self._pulse end

function CommitLatchTicket:commit(ctx, expected_proposal)
	if ctx.gate_state == op2.GATE_ABORTED then return TAG_CANCELLED, nil, nil end
	if ctx.gate_state ~= op2.GATE_COMMITTING then return TAG_CANCELLED, nil, nil end
	if expected_proposal ~= self._proposal then return TAG_PENDING, nil, self._pulse end
	if not self._can_commit then return TAG_PENDING, nil, self._pulse end
	return TAG_DONE, self._payload, nil
end

function CommitLatchTicket:cancel(_ctx) end

local function make_commit_latch_primitive(value)
	local pulse = op2.new_pulse()
	local proposal = {}
	local inst = ticket_new(CommitLatchTicket, {
		_pulse = pulse,
		_proposal = proposal,
		_can_commit = false,
		_payload = pack(value),
	})

	local op = prim_from_ticket(inst)

	local ctl = {}
	function ctl:allow_commit()
		inst._can_commit = true
		pulse:signal()
	end

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

	local node = {
		_pulse  = nil, _prev = nil, _next = nil, _linked = false,
		_task   = task,
		_waker  = runtime.current_scheduler,
	}

	local linked = pulse:subscribe_node(pulse._epoch, node)
	assert_true(linked, 'expected node to be linked')

	pulse:signal()
	tick()
	assert_eq(ran, 1, 'expected task to run after signal')

	assert_false(node._linked, 'expected node to be unlinked after signal')
	assert_eq(node._pulse, nil, 'expected node pulse cleared')

	local linked2 = pulse:subscribe_node(pulse._epoch - 1, node)
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
	assert_eq(calls, 1)

	local v2 = op2.perform(op2.always(5):wrap(f))
	assert_eq(v2, 10)
	assert_eq(calls, 2)
end)

test('wrap propagates errors from f()', function ()
	local function boom()
		error('boom', 0)
	end

	local ok, err = pcall(function ()
		op2.perform(op2.always('x'):wrap(boom))
	end)

	assert_false(ok)
	assert_true(tostring(err):match('boom') ~= nil)
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

	assert_eq(fin_aborted, true)
	assert_eq(abort_calls, 1)
end)

test('perform progresses when commit is pending and a pulse is signalled', function ()
	local op, ctl = make_commit_latch_primitive('ok')

	schedule(function ()
		ctl:allow_commit()
	end)

	local v = op2.perform(op)
	assert_eq(v, 'ok')
end)

test('choice retries when commit cannot reify the previewed proposal (pending + pulse)', function ()
	local commit_calls = 0
	local phase = 0

	local FlakyTicket = ticket_class({})

	function FlakyTicket:pulse() return self._pulse end
	function FlakyTicket:preview(_ctx2) return TAG_PREVIEW, self._current, self._payload, self._pulse end

	function FlakyTicket:commit(ctx2, expected_proposal)
		if ctx2.gate_state == op2.GATE_ABORTED then return TAG_CANCELLED, nil, nil end
		if ctx2.gate_state ~= op2.GATE_COMMITTING then return TAG_CANCELLED, nil, nil end

		commit_calls = commit_calls + 1

		if phase == 0 and expected_proposal == self._p1 then
			phase = 1
			self._current = self._p2
			self._pulse:signal()
			return TAG_PENDING, nil, self._pulse
		end

		if expected_proposal ~= self._current then
			return TAG_PENDING, nil, self._pulse
		end

		return TAG_DONE, self._payload, nil
	end

	function FlakyTicket:cancel(_ctx2) end

	local flaky = op2.new_primitive(function (_ctx)
		local pulse = op2.new_pulse()
		local p1 = {}
		local p2 = {}
		return ticket_new(FlakyTicket, {
			_pulse = pulse,
			_p1 = p1,
			_p2 = p2,
			_current = p1,
			_payload = pack('value'),
		})
	end)

	local v = op2.perform(op2.choice(flaky, op2.never()))
	assert_eq(v, 'value')
	assert_eq(commit_calls, 2)
end)

test('all(...) returns table of packed child values on success', function ()
	local res = op2.perform(op2.all(op2.always(1), op2.always(2)))
	assert_tbl(res)

	assert_tbl(res[1])
	assert_tbl(res[2])

	assert_pack_eq(res[1], { 1 })
	assert_pack_eq(res[2], { 2 })
end)

test('all retries when a child commit cannot reify prepared proposal (pending + pulse)', function ()
	local commit_calls = 0
	local phase = 0

	local ChildTicket = ticket_class({})

	function ChildTicket:pulse() return self._pulse end
	function ChildTicket:preview(_ctx2) return TAG_PREVIEW, self._current, self._payload, self._pulse end

	function ChildTicket:commit(ctx2, expected_proposal)
		if ctx2.gate_state == op2.GATE_ABORTED then return TAG_CANCELLED, nil, nil end
		if ctx2.gate_state ~= op2.GATE_COMMITTING then return TAG_CANCELLED, nil, nil end

		commit_calls = commit_calls + 1

		if phase == 0 and expected_proposal == self._p1 then
			phase = 1
			self._current = self._p2
			self._pulse:signal()
			return TAG_PENDING, nil, self._pulse
		end

		if expected_proposal ~= self._current then
			return TAG_PENDING, nil, self._pulse
		end

		return TAG_DONE, self._payload, nil
	end

	function ChildTicket:cancel(_ctx2) end

	local child = op2.new_primitive(function (_ctx)
		local pulse = op2.new_pulse()
		local p1 = {}
		local p2 = {}
		return ticket_new(ChildTicket, {
			_pulse = pulse,
			_p1 = p1,
			_p2 = p2,
			_current = p1,
			_payload = pack('x'),
		})
	end)

	local res = op2.perform(op2.all(child, op2.always('y')))
	assert_eq(commit_calls, 2)
	assert_pack_eq(res[1], { 'x' })
	assert_pack_eq(res[2], { 'y' })
end)

test('and_then rebuilds RHS when LHS proposal changes (ticket-level)', function ()
	local left_ticket, left_ctl = make_manual_ticket({ initial = 'pending' })
	local left_op = prim_from_ticket(left_ticket)

	local rhs_cancelled = 0

	local function rhs_for(x)
		local RHSTicket = ticket_class({})
		function RHSTicket:pulse() return self._pulse end
		function RHSTicket:preview(_ctx2) return TAG_PREVIEW, self._prop, self._payload, self._pulse end
		function RHSTicket:commit(ctx2, expected_proposal)
			if ctx2.gate_state == op2.GATE_ABORTED then return TAG_CANCELLED, nil, nil end
			if ctx2.gate_state ~= op2.GATE_COMMITTING then return TAG_CANCELLED, nil, nil end
			if expected_proposal ~= self._prop then return TAG_PENDING, nil, self._pulse end
			return TAG_DONE, self._payload, nil
		end
		function RHSTicket:cancel(_ctx2) rhs_cancelled = rhs_cancelled + 1 end

		return op2.new_primitive(function (_ctx)
			return ticket_new(RHSTicket, {
				_pulse = op2.new_pulse(),
				_prop  = {},
				_payload = pack(x * 10),
			})
		end)
	end

	local op = left_op:and_then(function (x) return rhs_for(x) end)

	local scheduler = runtime.current_scheduler
	local ctx = {
		gate_state = op2.GATE_OPEN,
		scheduler  = scheduler,
		_wait_node = { _linked = false, _task = runtime.current_fiber(), _waker = scheduler },
	}
	local root = op:_instantiate(ctx)

	left_ctl:set_preview({}, 1)
	local tag, _prop, payload = root:preview(ctx)
	assert_eq(tag, TAG_PREVIEW)
	assert_eq(payload[1], 10)

	left_ctl:set_preview({}, 2)
	local tag2, _prop2, payload2 = root:preview(ctx)
	assert_eq(tag2, TAG_PREVIEW)
	assert_eq(payload2[1], 20)

	assert_true(rhs_cancelled >= 1)
end)

test('bracket releases on success (aborted=false)', function ()
	local acquired = 0
	local releases = {}

	local function acquire()
		acquired = acquired + 1
		return { id = acquired }
	end

	local function release(res, aborted)
		releases[#releases + 1] = { res = res, aborted = aborted }
	end

	local op = op2.bracket(acquire, release, function (_res)
		return op2.always('ok')
	end)

	local v = op2.perform(op)
	assert_eq(v, 'ok')

	assert_eq(acquired, 1)
	assert_eq(#releases, 1)
	assert_eq(releases[1].aborted, false)
end)

test('bracket releases on abort via losing in choice (aborted=true)', function ()
	local acquired = 0
	local releases = {}

	local function acquire()
		acquired = acquired + 1
		return { id = acquired }
	end

	local function release(res, aborted)
		releases[#releases + 1] = { res = res, aborted = aborted }
	end

	local loser = op2.bracket(acquire, release, function (_res)
		return op2.never()
	end)

	local v = op2.perform(op2.choice(op2.always('winner'), loser))
	assert_eq(v, 'winner')

	assert_eq(acquired, 1)
	assert_eq(#releases, 1)
	assert_eq(releases[1].aborted, true)
end)

test('wrap composition order: op:wrap(f1):wrap(f2) == f2(f1(x))', function ()
	local trace = {}

	local function f1(x) trace[#trace + 1] = 'f1'; return x + 1 end
	local function f2(x) trace[#trace + 1] = 'f2'; return x * 10 end

	local v = op2.perform(op2.always(2):wrap(f1):wrap(f2))
	assert_eq(v, 30)
	assert_eq(trace[1], 'f1')
	assert_eq(trace[2], 'f2')
end)

test('wrap caching across repeated preview calls (no double-application)', function ()
	local calls = 0
	local function f(x) calls = calls + 1; return x + 1 end

	local p1 = {}
	local ticket, ctl = make_manual_ticket({ initial = 'preview', proposal = p1, values = pack(1) })
	local op = prim_from_ticket(ticket):wrap(f)

	local scheduler = runtime.current_scheduler
	local ctx = {
		gate_state = op2.GATE_OPEN,
		scheduler  = scheduler,
		_wait_node = { _linked = false, _task = runtime.current_fiber(), _waker = scheduler },
	}

	local root = op:_instantiate(ctx)

	local tag, prop, payload = root:preview(ctx)
	assert_eq(tag, TAG_PREVIEW)
	assert_eq(prop, p1)
	assert_eq(payload[1], 2)
	assert_eq(calls, 1)

	local tag2, prop2, payload2 = root:preview(ctx)
	assert_eq(tag2, TAG_PREVIEW)
	assert_eq(prop2, p1)
	assert_eq(payload2[1], 2)
	assert_eq(calls, 1)

	local p2 = {}
	ctl:set_preview(p2, 10)
	local tag3, prop3, payload3 = root:preview(ctx)
	assert_eq(tag3, TAG_PREVIEW)
	assert_eq(prop3, p2)
	assert_eq(payload3[1], 11)
	assert_eq(calls, 2)
end)

test('finally runs once even if cancel/abort is invoked after commit', function ()
	local ran = 0
	local aborted_seen = {}

	local p = {}
	local ticket, _ctl = make_manual_ticket({ initial = 'preview', proposal = p, values = pack('ok') })
	local op = prim_from_ticket(ticket):finally(function (aborted)
		ran = ran + 1
		aborted_seen[#aborted_seen + 1] = aborted
	end)

	local scheduler = runtime.current_scheduler
	local ctx = {
		gate_state = op2.GATE_OPEN,
		scheduler  = scheduler,
		_wait_node = { _linked = false, _task = runtime.current_fiber(), _waker = scheduler },
	}
	local root = op:_instantiate(ctx)

	local tag, prop = root:preview(ctx)
	assert_eq(tag, TAG_PREVIEW)
	assert_eq(prop, p)

	ctx.gate_state = op2.GATE_COMMITTING
	local ctag, payload = root:commit(ctx, p)
	assert_eq(ctag, TAG_DONE)
	assert_eq(payload[1], 'ok')
	assert_eq(ran, 1)
	assert_eq(aborted_seen[1], false)

	ctx.gate_state = op2.GATE_OPEN
	if root._post_commit_abort then root:_post_commit_abort(ctx) end
	root:cancel(ctx)

	assert_eq(ran, 1)
	assert_eq(#aborted_seen, 1)
end)

test('finally and on_abort swallow handler errors (best-effort)', function ()
	local fin_ran = 0
	local abort_ran = 0

	local loser =
		op2.never()
			:finally(function (_aborted) fin_ran = fin_ran + 1; error('finally-boom', 0) end)
			:on_abort(function () abort_ran = abort_ran + 1; error('abort-boom', 0) end)

	local v = op2.perform(op2.choice(op2.always('winner'), loser))
	assert_eq(v, 'winner')
	assert_eq(fin_ran, 1)
	assert_eq(abort_ran, 1)
end)

test('choice skips cancelled arms and can still succeed', function ()
	local t1, ctl1 = make_manual_ticket({ initial = 'cancelled' })
	local cancelled = prim_from_ticket(t1)

	local v = op2.perform(op2.choice(cancelled, op2.always('ok')))
	assert_eq(v, 'ok')
	assert_true(ctl1:cancels() >= 1)
end)

test('choice cancels when all arms are cancelled', function ()
	local t1 = make_manual_ticket({ initial = 'cancelled' })
	local t2 = make_manual_ticket({ initial = 'cancelled' })
	local cancelled1 = prim_from_ticket((t1))
	local cancelled2 = prim_from_ticket((t2))

	local ok = pcall(function ()
		op2.perform(op2.choice(cancelled1, cancelled2))
	end)
	assert_false(ok)
end)

test('all cancels if any arm is cancelled during preview (cancel_all contract)', function ()
	local t_bad, ctl_bad = make_manual_ticket({ initial = 'cancelled' })
	local t_other, ctl_other = make_manual_ticket({ initial = 'preview', proposal = {}, values = pack(1) })

	local bad   = prim_from_ticket(t_bad)
	local other = prim_from_ticket(t_other)

	local ok = pcall(function ()
		op2.perform(op2.all(other, bad))
	end)
	assert_false(ok)

	assert_true(ctl_other:cancels() >= 1)
	assert_true(ctl_bad:cancels() >= 1)
end)

test('choose2 returns table-of-packs and aborts/cancels the unchosen arms', function ()
	local fin_aborted = nil
	local abort_calls = 0

	local t3, ctl3 = make_manual_ticket({ initial = 'preview', proposal = {}, values = pack(99) })
	local third =
		prim_from_ticket(t3)
			:finally(function (aborted) fin_aborted = aborted end)
			:on_abort(function () abort_calls = abort_calls + 1 end)

	local res = op2.perform(op2.choose2(op2.always(1), op2.always(2), third))
	assert_tbl(res)
	assert_pack_eq(res[1], { 1 })
	assert_pack_eq(res[2], { 2 })

	assert_eq(fin_aborted, true)
	assert_eq(abort_calls, 1)
	assert_true(ctl3:cancels() >= 1)
end)

test('choose_k skips cancelled arms and still selects k ready results', function ()
	local t_bad, ctl_bad = make_manual_ticket({ initial = 'cancelled' })
	local bad = prim_from_ticket(t_bad)

	local res = op2.perform(op2.choose_k(2, bad, op2.always('a'), op2.always('b')))
	assert_tbl(res)
	assert_pack_eq(res[1], { 'a' })
	assert_pack_eq(res[2], { 'b' })

	assert_true(ctl_bad:cancels() >= 1)
end)

test('choice does not abort loser before winner commit completes', function ()
	local abort_calls = 0
	local loser =
		op2.always('loser')
			:on_abort(function () abort_calls = abort_calls + 1 end)

	local winner, ctl = make_commit_latch_primitive('winner')

	local mid_abort = nil
	schedule(function ()
		mid_abort = abort_calls
		ctl:allow_commit()
	end)

	local v = op2.perform(op2.choice(winner, loser))
	assert_eq(v, 'winner')

	assert_eq(mid_abort, 0)
	assert_eq(abort_calls, 1)
end)

test('guard thunk runs once per perform, even if commit retries', function ()
	local calls = 0
	local inner, ctl = make_commit_latch_primitive('ok')

	local guarded = op2.guard(function ()
		calls = calls + 1
		return inner
	end)

	schedule(function ()
		ctl:allow_commit()
	end)

	local v = op2.perform(guarded)
	assert_eq(v, 'ok')
	assert_eq(calls, 1)
end)

test('and_then runs LHS finally(false) on success and returns RHS result', function ()
	local seen = {}

	local v = op2.perform(
		op2.always(2)
			:finally(function (aborted) seen[#seen + 1] = aborted end)
			:and_then(function (x) return op2.always(x * 10) end)
	)

	assert_eq(v, 20)
	assert_eq(#seen, 1)
	assert_eq(seen[1], false)
end)

test('and_then cancels old RHS instance when LHS proposal changes; RHS finally(true) runs', function ()
	local left_ticket, left_ctl = make_manual_ticket({ initial = 'pending' })
	local left_op = prim_from_ticket(left_ticket)

	local rhs_aborts = 0
	local function rhs_for(x)
		return op2.always(x * 10):finally(function (aborted)
			if aborted then rhs_aborts = rhs_aborts + 1 end
		end)
	end

	local op = left_op:and_then(function (x) return rhs_for(x) end)

	local scheduler = runtime.current_scheduler
	local ctx = {
		gate_state = op2.GATE_OPEN,
		scheduler  = scheduler,
		_wait_node = { _linked = false, _task = runtime.current_fiber(), _waker = scheduler },
	}
	local root = op:_instantiate(ctx)

	left_ctl:set_preview({}, 1)
	local tag1, _p1, payload1 = root:preview(ctx)
	assert_eq(tag1, TAG_PREVIEW)
	assert_eq(payload1[1], 10)

	left_ctl:set_preview({}, 2)
	local tag2, _p2, payload2 = root:preview(ctx)
	assert_eq(tag2, TAG_PREVIEW)
	assert_eq(payload2[1], 20)

	assert_true(rhs_aborts >= 1)
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

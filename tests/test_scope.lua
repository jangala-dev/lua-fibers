--- Tests the Scope implementation (updated for new fibers.scope).
print('test: fibers.scope (new)')

-- look one level up
package.path = '../src/?.lua;' .. package.path

local runtime   = require 'fibers.runtime'
local scope_mod = require 'fibers.scope'
local op        = require 'fibers.op'
local performer = require 'fibers.performer'
local cond_mod  = require 'fibers.cond'

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

local unpack = rawget(table, 'unpack') or _G.unpack

local function unpack_packed(p)
	assert(type(p) == 'table', 'expected packed table')
	local n = p.n or #p
	return unpack(p, 1, n)
end

local function assert_contains(hay, needle, msg)
	assert(type(hay) == 'string', 'assert_contains expects string haystack')
	assert(hay:find(needle, 1, true), msg or ('expected to find ' .. tostring(needle)))
end

-------------------------------------------------------------------------------
-- 0. Outside-fibre current() snapshot
-------------------------------------------------------------------------------

do
	local r = scope_mod.root()
	assert(scope_mod.current() == r, 'outside fibres, current() should be root/global scope')
end

-------------------------------------------------------------------------------
-- 1. Current scope installation and restoration (run / nested run)
-------------------------------------------------------------------------------

local function test_current_scope_run_restores()
	local root = scope_mod.root()
	assert(scope_mod.current() == root, 'test harness fibre should see current() == root')

	local outer_ref, inner_ref

	local st, val, rep = scope_mod.run(function (s)
		outer_ref = s
		assert(scope_mod.current() == s, 'inside scope.run, current() should be the child scope')

		local st2, val2, rep2 = scope_mod.run(function (s2)
			inner_ref = s2
			assert(scope_mod.current() == s2, 'inside nested scope.run, current() should be nested child')
			return 1, 2, 3
		end)

		assert(st2 == 'ok', 'nested scope.run should succeed')
		local a, b, c = unpack_packed(val2)
		assert(a == 1 and b == 2 and c == 3, 'nested scope.run should return packed body results')
		assert(type(rep2) == 'table' and rep2.id ~= nil, 'nested scope.run should return a report')

		assert(scope_mod.current() == s, 'after nested run, current() should restore to outer child scope')

		return 'outer-result'
	end)

	assert(st == 'ok', 'outer scope.run should succeed')
	assert(type(rep) == 'table' and rep.id ~= nil, 'outer scope.run should return a report')
	local r1 = unpack_packed(val)
	assert(r1 == 'outer-result', 'outer scope.run should return packed body results')

	assert(scope_mod.current() == root, 'after scope.run returns, current() should restore to root in this fibre')

	assert(outer_ref ~= nil and inner_ref ~= nil, 'outer/inner scopes should have been captured')
	assert(outer_ref ~= inner_ref, 'outer and inner scopes must differ')

	-- join_op should be idempotent and immediate after run has joined the scope
	do
		local jst, jprimary, jrep = op.perform_raw(outer_ref:join_op())
		assert(jst == 'ok' and jprimary == nil, 'join_op on already-joined ok scope should be ok')
		assert(jrep and jrep.id == rep.id, 'join_op report id should match')
	end
end

-------------------------------------------------------------------------------
-- 2. Structural lifetime: attached children are joined by parent join
-------------------------------------------------------------------------------

local function test_structural_lifetime_attached_children_joined()
	local child1_ref, child2_ref
	local child1_done, child2_done = false, false

	local st, val_or_primary, rep = scope_mod.run(function (s)
		local c1, err1 = s:child()
		assert(c1, 'expected child1, got err: ' .. tostring(err1))
		child1_ref = c1

		local c2, err2 = s:child()
		assert(c2, 'expected child2, got err: ' .. tostring(err2))
		child2_ref = c2

		local ok1, se1 = c1:spawn(function (_)
			runtime.yield()
			child1_done = true
		end)
		assert(ok1 and se1 == nil, 'child1:spawn should be admitted')

		local ok2, se2 = c2:spawn(function (_)
			runtime.yield()
			child2_done = true
		end)
		assert(ok2 and se2 == nil, 'child2:spawn should be admitted')

		return 'parent-ok'
	end)

	assert(st == 'ok', 'parent scope should be ok')
	assert(unpack_packed(val_or_primary) == 'parent-ok', 'parent run should return packed results')
	assert(type(rep) == 'table' and type(rep.children) == 'table', 'report should include children array')

	assert(child1_done and child2_done, 'parent join should have waited for attached children work')

	assert(#rep.children == 2, 'expected two child outcomes in report')
	assert(rep.children[1].id == child1_ref._id, 'first child outcome should correspond to first attachment')
	assert(rep.children[2].id == child2_ref._id, 'second child outcome should correspond to second attachment')
	assert(rep.children[1].status == 'ok', 'child1 should end ok')
	assert(rep.children[2].status == 'ok', 'child2 should end ok')

	-- Joined child scopes should not admit new work
	do
		local ch, err = child1_ref:child()
		assert(ch == nil and err ~= nil, 'joined child scope should not admit new child scopes')
	end
end

-------------------------------------------------------------------------------
-- 3. Admission gate: close() and cancel() stop new spawn/child
-------------------------------------------------------------------------------

local function test_admission_close_and_cancel()
	local st, val_or_primary, rep = scope_mod.run(function (s)
		local ast, _ = s:admission()
		assert(ast == 'open', 'new scope admission should be open')

		s:close()
		s:close('closed-later')

		local ast2, areason2 = s:admission()
		assert(ast2 == 'closed' and areason2 == 'closed-later', 'close() should close admission and record reason')

		local ok, err = s:spawn(function () end)
		assert(ok == false and err ~= nil, 'spawn should be rejected when scope is closed')
		assert_contains(tostring(err), 'scope is closed', 'close admission error should mention closed')

		local child, cerr = s:child()
		assert(child == nil and cerr ~= nil, 'child() should be rejected when scope is closed')
		assert_contains(tostring(cerr), 'scope is closed', 'child admission error should mention closed')

		local cst, creason = op.perform_raw(s:close_op())
		assert(cst == 'closed' and creason == 'closed-later', 'close_op should yield closed + reason')

		return 'ok'
	end)

	assert(st == 'ok', 'scope.run should succeed')
	assert(unpack_packed(val_or_primary) == 'ok', 'body result should be returned')
	assert(rep and rep.id ~= nil, 'report should be present')

	local st2, primary2 = scope_mod.run(function (s)
		s:cancel('bye')
	end)
	assert(st2 == 'cancelled' and primary2 == 'bye', 'explicit cancel should yield cancelled + reason')
end

-------------------------------------------------------------------------------
-- 4. scope.run boundary when parent is not admitting work
-------------------------------------------------------------------------------

local function test_run_when_parent_closed_is_cancelled_boundary()
	local st, val_or_primary = scope_mod.run(function (s)
		s:close('no more children')

		local st2, v2, rep2 = scope_mod.run(function (_)
			return 1
		end)

		assert(st2 == 'cancelled', 'nested run should be cancelled when parent is closed')
		assert_contains(tostring(v2), 'scope is closed', 'nested run should surface admission error')
		assert(rep2 and rep2.id == s._id, 'nested run report should be based on parent scope')

		return 'parent-ok'
	end)

	assert(st == 'ok', 'outer run should remain ok')
	assert(unpack_packed(val_or_primary) == 'parent-ok', 'outer body should complete')
end

-------------------------------------------------------------------------------
-- 5. Cancellation sentinel and cancellation-as-control-flow
-------------------------------------------------------------------------------

local function test_cancellation_sentinel_and_non_failure()
	-- (A) cancellation escaping a fibre should not mark failure
	local st, primary = scope_mod.run(function (s)
		local c = cond_mod.new()

		local ok, err = s:spawn(function (_)
			s:perform(c:wait_op())
		end)
		assert(ok and err == nil, 'spawn should be admitted')

		runtime.yield()
		s:cancel('bye')
	end)

	assert(st == 'cancelled' and primary == 'bye',
		'cancellation escaping a fibre should yield cancelled scope, not failed')

	-- (B) perform should raise a distinguishable cancellation sentinel
	local st2, primary2 = scope_mod.run(function (s)
		local c = cond_mod.new()

		s:spawn(function (_)
			runtime.yield()
			s:cancel('cancel-reason')
		end)

		local ok, err = pcall(function ()
			s:perform(c:wait_op())
		end)

		assert(ok == false, 'perform should raise on cancellation')
		assert(scope_mod.is_cancelled(err), 'raised value should be a cancellation sentinel')
		assert(scope_mod.cancel_reason(err) == 'cancel-reason', 'cancellation sentinel should carry reason')
	end)

	assert(st2 == 'cancelled' and primary2 == 'cancel-reason', 'scope should be cancelled with the correct reason')
end

-------------------------------------------------------------------------------
-- 6. Fail-fast on first fault: siblings observe failure (not cancellation)
-------------------------------------------------------------------------------

local function test_fail_fast_and_siblings_observe_failure()
	local observed_st, observed_primary

	local st, primary, rep = scope_mod.run(function (s)
		local c = cond_mod.new()

		-- Sibling that will be interrupted by fail-fast.
		s:spawn(function (_)
			observed_st, observed_primary = s:try(c:wait_op())
		end)

		-- Failing sibling.
		s:spawn(function (_)
			error('boom')
		end)

		-- Give the siblings a chance to start.
		runtime.yield()
	end)

	assert(st == 'failed', 'scope should fail on first fault')
	assert_contains(tostring(primary), 'boom', 'primary fault should mention the failing error')

	assert(observed_st == 'failed', 'blocked sibling should observe failed (not cancelled) when a fault occurs')
	assert_contains(tostring(observed_primary), 'boom',
		'blocked sibling failure should reflect the primary fault')

	-- No extra errors should be recorded (the blocked sibling returned normally).
	assert(rep and type(rep.extra_errors) == 'table', 'report should include extra_errors')
	assert(#rep.extra_errors == 0, 'extra_errors should be empty when siblings exit without additional faults')
end

-------------------------------------------------------------------------------
-- 7. cancel_op / fault_op / not_ok_op behaviour and precedence
-------------------------------------------------------------------------------

local function test_not_ok_ops()
	local st1, primary1 = scope_mod.run(function (s)
		s:spawn(function (_)
			runtime.yield()
			s:cancel('cancelled-here')
		end)

		local ost, oval = op.perform_raw(s:cancel_op())
		assert(ost == 'cancelled' and oval == 'cancelled-here', 'cancel_op should yield cancelled + reason')
	end)
	assert(st1 == 'cancelled' and primary1 == 'cancelled-here', 'scope should be cancelled')

	local st2, primary2 = scope_mod.run(function (s)
		s:spawn(function (_)
			runtime.yield()
			error('fault-here')
		end)

		local ost, oval = op.perform_raw(s:fault_op())
		assert(ost == 'failed', 'fault_op should yield failed')
		assert_contains(tostring(oval), 'fault-here', 'fault_op primary should mention the fault')
	end)
	assert(st2 == 'failed', 'scope should be failed on fault')
	assert_contains(tostring(primary2), 'fault-here', 'scope primary should mention the fault')

	local st3, primary3 = scope_mod.run(function (s)
		s:spawn(function (_)
			runtime.yield()
			error('precedence-fault')
		end)

		local ost, oval = op.perform_raw(s:not_ok_op())
		assert(ost == 'failed', 'not_ok_op should prefer failed if a fault occurs')
		assert_contains(tostring(oval), 'precedence-fault', 'not_ok_op should carry the primary fault')
	end)
	assert(st3 == 'failed', 'scope should be failed in precedence test')
	assert_contains(tostring(primary3), 'precedence-fault', 'scope primary should mention precedence-fault')
end

-------------------------------------------------------------------------------
-- 8. Finalisers: LIFO order; cancellation sentinel in finaliser becomes fault
-------------------------------------------------------------------------------

local function test_finalisers_lifo_and_cancel_in_finaliser()
	local order = {}

	local st, val_or_primary = scope_mod.run(function (s)
		s:finally(function () table.insert(order, 'first') end)
		s:finally(function () table.insert(order, 'second') end)
		return 'ok'
	end)

	assert(st == 'ok', 'scope should be ok when body and finalisers succeed')
	assert(unpack_packed(val_or_primary) == 'ok', 'body result should be returned on ok')
	assert(#order == 2 and order[1] == 'second' and order[2] == 'first', 'finalisers should run LIFO')

	local st2, primary2 = scope_mod.run(function (s)
		s:finally(function ()
			error(scope_mod.cancelled('finaliser-cancel'))
		end)
		return 'ok'
	end)

	assert(st2 == 'failed', 'cancellation sentinel from finaliser should fail the scope')
	assert_contains(tostring(primary2), 'finaliser raised cancellation', 'primary should mention finaliser cancellation')
	assert_contains(tostring(primary2), 'finaliser-cancel', 'primary should include the cancellation reason')
end

-------------------------------------------------------------------------------
-- 9. Reports: children outcomes and extra_errors
-------------------------------------------------------------------------------

local function test_reports_children_and_extra_errors()
	local st, primary, rep = scope_mod.run(function (s)
		local ch, err = s:child()
		assert(ch, 'expected child scope, got: ' .. tostring(err))

		ch:spawn(function (_)
			error('child-fault')
		end)

		-- LIFO: finaliser-2 runs first and becomes primary, finaliser-1 becomes extra.
		s:finally(function () error('finaliser-1') end)
		s:finally(function () error('finaliser-2') end)

		return 'body-ok'
	end)

	assert(st == 'failed', 'finaliser failure should fail the scope')
	assert(rep and rep.id ~= nil and type(rep.children) == 'table', 'report should be present')
	assert(#rep.children == 1, 'report should include one child outcome')

	assert_contains(tostring(rep.children[1].primary), 'child-fault',
		'child outcome primary should mention child fault')

	assert_contains(tostring(primary), 'finaliser-2', 'primary should come from the first failing finaliser (LIFO)')

	assert(type(rep.extra_errors) == 'table', 'report.extra_errors should be a table')
	assert(#rep.extra_errors >= 1, 'expected at least one extra error')
	local joined = table.concat(rep.extra_errors, '\n')
	assert_contains(joined, 'finaliser-1', 'extra_errors should include the later finaliser failure')
end

-------------------------------------------------------------------------------
-- 10. Join closes admission: once join starts, spawn/child are rejected
-------------------------------------------------------------------------------

local function test_join_closes_admission_and_rejects_new_work()
	local st, val_or_primary = scope_mod.run(function (s)
		local child, err = s:child()
		assert(child, 'expected child scope, got: ' .. tostring(err))

		local blocker     = cond_mod.new()
		local join_started = cond_mod.new()

		-- Keep the child scope busy so join has something to wait for.
		child:spawn(function (_)
			child:perform(blocker:wait_op())
		end)

		-- Start joining the child from a sibling fibre in the parent scope.
		s:spawn(function (_)
			join_started:signal()
			op.perform_raw(child:join_op())
		end)

		-- Wait until join has started (this is enough: join worker closes admission immediately).
		performer.perform(join_started:wait_op())
		runtime.yield()

		local ok1, e1 = child:spawn(function () end)
		assert(ok1 == false and e1 ~= nil, 'spawn should be rejected once join has started')
		assert_contains(tostring(e1), 'scope is joining', 'spawn admission error should mention joining')

		local c2, e2 = child:child()
		assert(c2 == nil and e2 ~= nil, 'child() should be rejected once join has started')
		assert_contains(tostring(e2), 'scope is joining', 'child admission error should mention joining')

		-- Allow join to complete.
		blocker:signal()

		return 'ok'
	end)

	assert(st == 'ok', 'join/admission test should complete ok')
	assert(unpack_packed(val_or_primary) == 'ok', 'join/admission test should return ok')
end

-------------------------------------------------------------------------------
-- 11. scope.with_op behaviour (status/value/report), failure confinement, abort
-------------------------------------------------------------------------------

local function test_with_op_basic()
	local parent = scope_mod.current()
	local child_ref

	local ev = scope_mod.with_op(function (child)
		child_ref = child
		assert(scope_mod.current() == child, 'inside with_op build_op, current() should be child scope')

		return op.always(true):wrap(function ()
			return 99, 'ok'
		end)
	end)

	local st, vals, rep = performer.perform(ev)
	assert(st == 'ok', 'with_op should return ok on success')
	assert(type(vals) == 'table', 'with_op ok result should carry packed values table')
	local a, b = unpack_packed(vals)
	assert(a == 99 and b == 'ok', 'with_op should propagate body op values via packed table')
	assert(rep and rep.id == child_ref._id, 'with_op report id should be child scope id')

	assert(scope_mod.current() == parent, 'after with_op, current() should restore to parent')
	local cst, cprimary = child_ref:status()
	assert(cst == 'ok' and cprimary == nil, 'with_op child scope should be ok after success')
end

local function test_with_op_builder_failure_confined()
	local st, val_or_primary = scope_mod.run(function (_)
		local child_ref

		local ev = scope_mod.with_op(function (child)
			child_ref = child
			error('with_op builder failure')
		end)

		local wst, wprimary, wrep = performer.perform(ev)
		assert(wst == 'failed', 'with_op should return failed when build_op errors')
		assert_contains(tostring(wprimary), 'with_op builder failure', 'with_op primary should mention builder failure')
		assert(wrep and wrep.id == child_ref._id, 'with_op report id should be child id')

		return 'outer-ok'
	end)

	assert(st == 'ok', 'outer scope should remain ok when with_op build fails')
	assert(unpack_packed(val_or_primary) == 'outer-ok', 'outer scope should return body results')
end

local function test_with_op_abort_on_choice()
	local child_ref

	local st, val_or_primary = scope_mod.run(function (_)
		local ev_with = scope_mod.with_op(function (child)
			child_ref = child
			return op.never()
		end)

		local ev_choice = op.choice(ev_with, op.always('right'))
		local res = performer.perform(ev_choice)
		assert(res == 'right', "choice should pick the always('right') arm")
		return res
	end)

	assert(st == 'ok', 'outer scope should remain ok when with_op arm loses a choice')
	assert(unpack_packed(val_or_primary) == 'right', 'outer scope should return choice result')

	assert(child_ref ~= nil, 'with_op should have created a child scope')
	local cst, cprimary = child_ref:status()
	assert(cst == 'cancelled', 'with_op child should be cancelled when aborted by choice loss')
	assert(cprimary == 'aborted', "with_op aborted child primary should be 'aborted'")
end

local function test_with_op_child_fibre_failure()
	local st, val_or_primary = scope_mod.run(function (_)
		local ev = scope_mod.with_op(function (child)
			child:spawn(function (_)
				error('with_op child fibre failure')
			end)
			return op.always('ok')
		end)

		local wst, wprimary = performer.perform(ev)
		assert(wst == 'failed', 'with_op should return failed when a child fibre fails')
		assert_contains(tostring(wprimary), 'with_op child fibre failure',
			'with_op primary should mention the child fibre failure')

		return 'outer-ok'
	end)

	assert(st == 'ok', 'outer scope should remain ok after with_op child fibre failure')
	assert(unpack_packed(val_or_primary) == 'outer-ok', 'outer scope should return body results')
end

-------------------------------------------------------------------------------
-- Test suite entry
-------------------------------------------------------------------------------

local function run_all_tests()
	test_current_scope_run_restores()
	test_structural_lifetime_attached_children_joined()

	test_admission_close_and_cancel()
	test_run_when_parent_closed_is_cancelled_boundary()

	test_cancellation_sentinel_and_non_failure()
	test_fail_fast_and_siblings_observe_failure()

	test_not_ok_ops()
	test_finalisers_lifo_and_cancel_in_finaliser()
	test_reports_children_and_extra_errors()

	test_join_closes_admission_and_rejects_new_work()

	test_with_op_basic()
	test_with_op_builder_failure_confined()
	test_with_op_abort_on_choice()
	test_with_op_child_fibre_failure()
end

-------------------------------------------------------------------------------
-- Main (avoid hangs; propagate failure to luajit exit code)
-------------------------------------------------------------------------------

local function main()
	io.stdout:write('Running scope tests...\n')

	local outcome = { ok = true, err = nil }

	local root = scope_mod.root()

	-- Run the suite in a fibre whose current scope is the root.
	-- Capture any failure ourselves so it does not become an uncaught fibre error,
	-- and so we can always stop the scheduler.
	root:spawn(function (_)
		local ok, err = xpcall(function ()
			run_all_tests()
		end, function (e)
			return debug.traceback(tostring(e), 2)
		end)

		outcome.ok = ok
		outcome.err = err

		runtime.stop()
	end)

	runtime.main()

	if not outcome.ok then
		error(outcome.err or 'scope tests failed')
	end

	io.stdout:write('OK\n')
end

main()

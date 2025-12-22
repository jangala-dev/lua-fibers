--- Revised tests for fibers.scope (status-first: st, rep, ...).
---
--- This suite aims to test contractual behaviour, avoid overfitting to
--- incidental implementation details, and cover concurrency edges:
---   - idempotent ops (join_op / close_op / cancel_op / fault_op)
---   - join non-interruptibility (finalisers always run)
---   - failure vs cancellation precedence
---   - admission races around run_op
---   - report structure (children ordering + nested reports)
---   - runtime uncaught error attribution path (best-effort; see note)
---
print('test: fibers.scope (revised contract-oriented suite)')

package.path = '../src/?.lua;' .. package.path

local runtime   = require 'fibers.runtime'
local scope_mod = require 'fibers.scope'
local op        = require 'fibers.op'
local performer = require 'fibers.performer'
local cond_mod  = require 'fibers.cond'
local safe      = require 'coxpcall'

-- Capture unscoped fiber errors during tests.
local unscoped = { n = 0, last = nil }

scope_mod.set_unscoped_error_handler(function (_, err)
	unscoped.n = unscoped.n + 1
	unscoped.last = err
end)

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

local function assert_contains(hay, needle, msg)
	assert(type(hay) == 'string', 'assert_contains expects string haystack')
	assert(hay:find(needle, 1, true), msg or ('expected to find ' .. tostring(needle)))
end

local function assert_is_report(rep, msg)
	assert(type(rep) == 'table', msg or 'expected report table')
	assert(rep.id ~= nil, msg or 'expected report.id')
	assert(type(rep.extra_errors) == 'table', msg or 'expected report.extra_errors table')
	assert(type(rep.children) == 'table', msg or 'expected report.children table')
end

local function run_in_root(fn)
	-- Run the suite in a fiber whose current scope is the root.
	-- Capture any failure so it does not become an uncaught fiber error.
	local outcome = { ok = true, err = nil }

	local root = scope_mod.root()
	root:spawn(function ()
		local ok, err = safe.xpcall(fn, function (e)
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
end

-------------------------------------------------------------------------------
-- 0. Outside-fiber current() behaviour (policy test; keep minimal)
-------------------------------------------------------------------------------

local function test_outside_fiber_current_is_root()
	local r = scope_mod.root()
	assert(scope_mod.current() == r, 'outside fibers, current() should be root scope')
end

-------------------------------------------------------------------------------
-- 1. Current scope installation and restoration (run and nested run)
-------------------------------------------------------------------------------

local function test_current_scope_run_restores()
	local root = scope_mod.root()
	assert(scope_mod.current() == root, 'test fiber should see current() == root')

	local outer_ref, inner_ref

	local st, rep, outer_val = scope_mod.run(function (s)
		outer_ref = s
		assert(scope_mod.current() == s, 'inside scope.run, current() should be the child scope')

		local st2, rep2, a, b, c = scope_mod.run(function (s2)
			inner_ref = s2
			assert(scope_mod.current() == s2, 'inside nested run, current() should be nested child')
			return 1, 2, 3
		end)

		assert(st2 == 'ok', 'nested run should succeed')
		assert_is_report(rep2, 'nested run should return a report')
		assert(a == 1 and b == 2 and c == 3, 'nested run should return body values')

		assert(scope_mod.current() == s, 'after nested run, current() should restore to outer child')
		return 'outer-result'
	end)

	assert(st == 'ok', 'outer run should succeed')
	assert_is_report(rep, 'outer run should return a report')
	assert(outer_val == 'outer-result', 'outer run should return body values')

	assert(scope_mod.current() == root, 'after run returns, current() should restore to root')

	assert(outer_ref and inner_ref and outer_ref ~= inner_ref, 'outer/inner scopes must be captured and differ')

	-- join_op should be idempotent and immediate after run has joined.
	local jst, jrep, jprimary = op.perform_raw(outer_ref:join_op())
	assert(jst == 'ok' and jprimary == nil, 'join_op on joined ok scope should be ok')
	assert_is_report(jrep, 'join_op should return a report')
	assert(jrep.id == rep.id, 'join_op report id should match the run report id')
end

-------------------------------------------------------------------------------
-- 2. Structural lifetime and join ordering (attachment order)
-------------------------------------------------------------------------------

local function test_structural_lifetime_children_joined_in_order()
	local child1_ref, child2_ref
	local child1_done, child2_done = false, false

	local st, rep, parent_val = scope_mod.run(function (s)
		local c1, err1 = s:child()
		assert(c1, 'expected child1, got err: ' .. tostring(err1))
		child1_ref = c1

		local c2, err2 = s:child()
		assert(c2, 'expected child2, got err: ' .. tostring(err2))
		child2_ref = c2

		local ok1 = c1:spawn(function ()
			runtime.yield()
			child1_done = true
		end)
		assert(ok1, 'child1:spawn should be admitted')

		local ok2 = c2:spawn(function ()
			runtime.yield()
			child2_done = true
		end)
		assert(ok2, 'child2:spawn should be admitted')

		return 'parent-ok'
	end)

	assert(st == 'ok', 'parent scope should be ok')
	assert_is_report(rep, 'parent report must be present')
	assert(parent_val == 'parent-ok', 'parent run should return body values')

	assert(child1_done and child2_done, 'parent join should wait for attached children work')

	-- Attachment order is a stated guarantee; test it.
	assert(#rep.children == 2, 'expected two child outcomes')
	assert(rep.children[1].id == child1_ref._id, 'first child outcome should correspond to first attachment')
	assert(rep.children[2].id == child2_ref._id, 'second child outcome should correspond to second attachment')
	assert(rep.children[1].status == 'ok' and rep.children[2].status == 'ok', 'children should end ok')

	-- Joined child scopes should reject new work (admission gated by join).
	local ch, err = child1_ref:child()
	assert(ch == nil and err ~= nil, 'joined child should reject new child')
	assert_contains(tostring(err), 'scope is joining', 'rejection should mention joining')
end

-------------------------------------------------------------------------------
-- 3. Admission gate: close() rejects spawn/child; close_op is idempotent
-------------------------------------------------------------------------------

local function test_admission_close_and_close_op_idempotent()
	local st, rep, body_val = scope_mod.run(function (s)
		local ast = s:admission()
		assert(ast == 'open', 'new scope admission should be open')

		s:close()
		s:close('closed-later') -- policy: allow setting reason after close if none set

		local ast2, areason2 = s:admission()
		assert(ast2 == 'closed', 'close should close admission')
		assert(areason2 == 'closed-later', 'close should record a later reason if none was set earlier')

		local ok, err = s:spawn(function () end)
		assert(ok == false and err ~= nil, 'spawn should be rejected when scope is closed')
		assert_contains(tostring(err), 'scope is closed', 'close rejection should mention closed')

		local child, cerr = s:child()
		assert(child == nil and cerr ~= nil, 'child should be rejected when scope is closed')
		assert_contains(tostring(cerr), 'scope is closed', 'child rejection should mention closed')

		-- close_op should resolve and be repeatable.
		local cst, creason = op.perform_raw(s:close_op())
		assert(cst == 'closed' and creason == 'closed-later', 'close_op yields closed + reason')

		local cst2, creason2 = op.perform_raw(s:close_op())
		assert(cst2 == 'closed' and creason2 == 'closed-later', 'close_op is idempotent')

		return 'ok'
	end)

	assert(st == 'ok', 'run should succeed')
	assert_is_report(rep, 'report should be present')
	assert(body_val == 'ok', 'body result should be returned')
end

-------------------------------------------------------------------------------
-- 4. cancel(): rejects new work; cancel_op idempotent; cancel reason policy
-------------------------------------------------------------------------------

local function test_cancel_and_cancel_op_idempotent()
	local st, rep, primary = scope_mod.run(function (s)
		s:cancel('bye')
	end)

	assert(st == 'cancelled' and primary == 'bye', 'explicit cancel yields cancelled + reason')
	assert_is_report(rep, 'cancelled scope should return a report')

	-- cancel_op should return cancelled and be idempotent (even post-join).
	local st2, rep2, primary2 = scope_mod.run(function (s)
		s:cancel('first')
		s:cancel('second') -- current policy: first wins
		local ost, oval = op.perform_raw(s:cancel_op())
		assert(ost == 'cancelled', 'cancel_op yields cancelled')
		assert(oval == 'first', 'cancel reason should follow first-wins policy')
	end)

	assert(st2 == 'cancelled' and primary2 == 'first', 'scope should be cancelled with first reason')
	assert_is_report(rep2, 'cancelled scope should return report')
end

-------------------------------------------------------------------------------
-- 5. Cancellation sentinel behaviour (perform raises sentinel; try returns status)
-------------------------------------------------------------------------------

local function test_cancellation_sentinel_and_try_semantics()
	local st, rep, primary = scope_mod.run(function (s)
		local c = cond_mod.new()

		s:spawn(function ()
			runtime.yield()
			s:cancel('cancel-reason')
		end)

		local ok, err = safe.pcall(function ()
			s:perform(c:wait_op())
		end)

		assert(ok == false, 'perform should raise on cancellation')
		assert(scope_mod.is_cancelled(err), 'raised value should be cancellation sentinel')
		assert(scope_mod.cancel_reason(err) == 'cancel-reason', 'sentinel should carry reason')

		local t_st, t_val = s:try(c:wait_op())
		assert(t_st == 'cancelled' and t_val == 'cancel-reason', 'try returns cancelled + reason')
	end)

	assert(st == 'cancelled' and primary == 'cancel-reason', 'scope ends cancelled with correct reason')
	assert_is_report(rep, 'cancelled report must be present')
end

-------------------------------------------------------------------------------
-- 6. Fail-fast: first fault cancels scope; siblings observe failure (not cancellation)
-------------------------------------------------------------------------------

local function test_fail_fast_and_siblings_observe_failed()
	local observed_st, observed_primary

	local st, rep, primary = scope_mod.run(function (s)
		local c = cond_mod.new()

		s:spawn(function ()
			observed_st, observed_primary = s:try(c:wait_op())
		end)

		s:spawn(function ()
			error('boom')
		end)

		runtime.yield()
	end)

	assert(st == 'failed', 'scope should fail on first fault')
	assert_contains(tostring(primary), 'boom', 'primary should mention boom')

	assert(observed_st == 'failed', 'blocked sibling should observe failed on fault')
	assert_contains(tostring(observed_primary), 'boom', 'blocked sibling should observe primary fault')

	assert_is_report(rep, 'report must be present')
	assert(#rep.extra_errors == 0, 'extra_errors should be empty when no further faults')
end

-------------------------------------------------------------------------------
-- 7. Failure takes precedence over cancellation (race)
-------------------------------------------------------------------------------

local function test_failure_precedes_cancellation()
	local st, rep, primary = scope_mod.run(function (s)
		s:spawn(function ()
			runtime.yield()
			s:cancel('cancelling')
		end)
		s:spawn(function ()
			runtime.yield()
			error('failing')
		end)
		runtime.yield()
		runtime.yield()
	end)

	assert(st == 'failed', 'failure should take precedence over cancellation')
	assert_contains(tostring(primary), 'failing')
	assert_is_report(rep, 'report must be present')
end

-------------------------------------------------------------------------------
-- 8. fault_op / not_ok_op behaviour and idempotency
-------------------------------------------------------------------------------

local function test_fault_ops_and_not_ok_precedence()
	local st1, rep1, primary1 = scope_mod.run(function (s)
		s:spawn(function ()
			runtime.yield()
			error('fault-here')
		end)

		local ost, oval = op.perform_raw(s:fault_op())
		assert(ost == 'failed', 'fault_op yields failed')
		assert_contains(tostring(oval), 'fault-here', 'fault_op yields primary fault')

		local nst, nval = op.perform_raw(s:not_ok_op())
		assert(nst == 'failed', 'not_ok_op yields failed when a fault occurs')
		assert_contains(tostring(nval), 'fault-here', 'not_ok_op yields the primary fault')
	end)

	assert(st1 == 'failed', 'scope should be failed on fault')
	assert_contains(tostring(primary1), 'fault-here')
	assert_is_report(rep1, 'failed report must be present')
end

-------------------------------------------------------------------------------
-- 9. Finalisers: LIFO order; join non-interruptible (finalisers run under cancel)
-------------------------------------------------------------------------------

local function test_finalisers_lifo_and_join_non_interruptible()
	-- (A) LIFO finalisers in the straightforward case
	local order = {}
	local st, rep, body_val = scope_mod.run(function (s)
		s:finally(function () table.insert(order, 'first') end)
		s:finally(function () table.insert(order, 'second') end)
		return 'ok'
	end)

	assert(st == 'ok' and body_val == 'ok', 'ok scope should return body result')
	assert_is_report(rep, 'report must be present')
	assert(#order == 2 and order[1] == 'second' and order[2] == 'first', 'finalisers run LIFO')

	-- (B) Join is non-interruptible: finalisers must run even if cancelled mid-join.
	--
	-- This test focuses on:
	--   * the CHILD reaches terminal state and runs its finalisers
	--   * the PARENT does not become not-ok because the child was cancelled
	local ran = false
	local child_ref

	local pst, prep, pprimary = scope_mod.run(function (s)
		local ch = assert(s:child())
		child_ref = ch

		local blocker = cond_mod.new()

		ch:spawn(function ()
			-- This should be interrupted by cancellation (via ch:perform semantics).
			ch:perform(blocker:wait_op())
		end)

		ch:finally(function ()
			ran = true
		end)

		-- Start joining the child in a sibling fiber.
		s:spawn(function ()
			op.perform_raw(ch:join_op())
		end)

		-- Let join start, then cancel the child.
		runtime.yield()
		ch:cancel('cancel-during-join')

		-- Give the join worker time to complete.
		runtime.yield()

		-- Parent body completes without error.
		return 'parent-ok'
	end)

	-- If this fails, print what actually happened to the parent so you can diagnose.
	assert(pst == 'ok', ('parent scope should remain ok in join test; got st=%s primary=%s')
		:format(tostring(pst), tostring(pprimary)))
	assert_is_report(prep, 'parent report must be present')

	-- Now assert the child actually finished cancelled and ran finalisers.
	assert(child_ref ~= nil, 'child scope must be captured')

	-- If join has completed, status() may be 'cancelled'/'failed'/'ok'; if not, it could be 'running'.
	-- We make it deterministic by calling join_op now (idempotent).
	local jst, jrep, jprim = op.perform_raw(child_ref:join_op())
	assert(jst == 'cancelled', ('child should end cancelled; got %s'):format(tostring(jst)))
	assert(jprim == 'cancel-during-join', 'child cancellation reason should be preserved')
	assert_is_report(jrep, 'child join should return a report')

	assert(ran, 'child finaliser must run even if cancelled during join')
end

-------------------------------------------------------------------------------
-- 10. Finaliser cancellation sentinel becomes fault (policy test)
-------------------------------------------------------------------------------

local function test_cancel_sentinel_in_finaliser_becomes_fault()
	local st, rep, primary = scope_mod.run(function (s)
		s:finally(function ()
			error(scope_mod.cancelled('finaliser-cancel'))
		end)
		return 'ok'
	end)

	assert(st == 'failed', 'cancellation sentinel in finaliser should fail scope (policy)')
	assert_is_report(rep, 'failed report must be present')
	assert_contains(tostring(primary), 'finaliser raised cancellation', 'primary should mention finaliser cancellation')
	assert_contains(tostring(primary), 'finaliser-cancel', 'primary should include cancellation reason')
end

-------------------------------------------------------------------------------
-- 11. Reports: nested child report structure (depth 2)
-------------------------------------------------------------------------------

local function test_reports_nested_children_depth_two()
	local child_ref, grand_ref

	local st, rep, body_val = scope_mod.run(function (s)
		local ch = assert(s:child())
		child_ref = ch
		local gch = assert(ch:child())
		grand_ref = gch

		gch:spawn(function ()
			error('grandchild-fault')
		end)

		return 'ok'
	end)

	-- Contract: no implicit upward failure propagation.
	assert(st == 'ok' and body_val == 'ok', 'parent scope should remain ok when attached children fail')
	assert_is_report(rep, 'report must be present')

	-- Parent report should contain child outcome; child report should contain grandchild outcome.
	assert(#rep.children == 1, 'expected one child outcome')
	assert(rep.children[1].id == child_ref._id, 'child outcome id should match')
	assert(rep.children[1].report and rep.children[1].report.id == child_ref._id, 'child report should be present')

	local child_rep = rep.children[1].report
	assert(
		type(child_rep.children) == 'table' and #child_rep.children == 1,
		'child report should include one grandchild outcome'
	)
	assert(child_rep.children[1].id == grand_ref._id, 'grandchild outcome id should match')
	assert(child_rep.children[1].status == 'failed', 'grandchild should have failed')
	assert_contains(tostring(child_rep.children[1].primary), 'grandchild-fault',
	'grandchild primary should mention fault')
end

-------------------------------------------------------------------------------
-- 12. Join closes admission: spawn/child rejected once joining has started
-------------------------------------------------------------------------------

local function test_join_closes_admission_and_rejects_new_work()
	local st, rep, body_val = scope_mod.run(function (s)
		local child = assert(s:child())

		local blocker      = cond_mod.new()
		local join_started = cond_mod.new()

		child:spawn(function ()
			child:perform(blocker:wait_op())
		end)

		s:spawn(function ()
			join_started:signal()
			op.perform_raw(child:join_op())
		end)

		performer.perform(join_started:wait_op())
		runtime.yield()

		local ok1, e1 = child:spawn(function () end)
		assert(ok1 == false and e1 ~= nil, 'spawn should be rejected once join has started')
		assert_contains(tostring(e1), 'scope is joining', 'spawn rejection should mention joining')

		local c2, e2 = child:child()
		assert(c2 == nil and e2 ~= nil, 'child() should be rejected once join has started')
		assert_contains(tostring(e2), 'scope is joining', 'child rejection should mention joining')

		blocker:signal()
		return 'ok'
	end)

	assert(st == 'ok' and body_val == 'ok', 'join/admission test should complete ok')
	assert_is_report(rep, 'report must be present')
end

-------------------------------------------------------------------------------
-- 13. run_op: basic success, confinement of failure, and abort on choice loss
-------------------------------------------------------------------------------

local function test_run_op_basic_and_failure_confinement()
	local parent = scope_mod.current()
	local child_ref

	local ev = scope_mod.run_op(function (child)
		child_ref = child
		assert(scope_mod.current() == child, 'inside run_op body, current() should be child')
		local a, b = child:perform(op.always(99, 'ok'))
		return a, b
	end)

	local st, rep, a, b = performer.perform(ev)
	assert(st == 'ok', 'run_op should return ok on success')
	assert_is_report(rep, 'run_op should return report')
	assert(a == 99 and b == 'ok', 'run_op should return body values')
	assert(rep.id == child_ref._id, 'run_op report id should match child scope id')

	assert(scope_mod.current() == parent, 'after run_op, current() should remain parent in this fiber')
	local cst, cprimary = child_ref:status()
	assert(cst == 'ok' and cprimary == nil, 'child scope should be ok after success')

	-- Failure confinement: failing run_op should not fail outer scope.
	local outer_st, outer_rep, outer_val = scope_mod.run(function ()
		local cref
		local ev2 = scope_mod.run_op(function (child)
			cref = child
			error('run_op body failure')
		end)

		local wst, wrep, wprimary = performer.perform(ev2)
		assert(wst == 'failed', 'run_op should yield failed on body error')
		assert_contains(tostring(wprimary), 'run_op body failure')
		assert_is_report(wrep, 'run_op should return report even on failure')
		assert(wrep.id == cref._id, 'report id should be child id')

		return 'outer-ok'
	end)

	assert(outer_st == 'ok' and outer_val == 'outer-ok', 'outer scope should remain ok')
	assert_is_report(outer_rep, 'outer report must be present')
end

local function test_run_op_abort_on_choice_loss()
	local child_ref

	local st, rep, outer_val = scope_mod.run(function (s)
		local ready = cond_mod.new()

		-- Ensure choice blocks so run_op starts.
		s:spawn(function ()
			runtime.yield()
			ready:signal()
		end)

		local ev_with = scope_mod.run_op(function (child)
			child_ref = child
			child:perform(op.never())
			return 'unexpected'
		end)

		local ev_right = ready:wait_op():wrap(function () return 'right' end)
		local ev_choice = op.choice(ev_with, ev_right)

		local res = performer.perform(ev_choice)
		assert(res == 'right', 'choice should select right arm once ready')
		return res
	end)

	assert(st == 'ok' and outer_val == 'right', 'outer scope should remain ok and return right')
	assert_is_report(rep, 'outer report must be present')

	assert(child_ref ~= nil, 'run_op should create child scope on blocking path')
	local cst, cprimary = child_ref:status()
	assert(cst == 'cancelled', 'aborted run_op child should be cancelled')
	assert(cprimary == 'aborted', "aborted child cancellation reason should be 'aborted'")
end

-------------------------------------------------------------------------------
-- 14. Admission race around run_op (parent closes before run_op can start)
-------------------------------------------------------------------------------

local function test_run_op_parent_closed_before_start_is_cancelled()
	local st, rep = scope_mod.run(function (s)
		s:close('no more')

		local ev = scope_mod.run_op(function ()
			return 1
		end)

		local wst, wrep, wprimary = performer.perform(ev)
		assert(wst == 'cancelled', 'run_op should be cancelled when parent is closed')
		assert_contains(tostring(wprimary), 'scope is closed')
		assert_is_report(wrep, 'run_op should return a report')
		assert(wrep.id == s._id, 'run_op cancelled report should be based on parent scope')
	end)

	assert(st == 'ok', 'outer scope should remain ok')
	assert_is_report(rep, 'outer report must be present')
end

-------------------------------------------------------------------------------
-- 15. Uncaught runtime fiber error attribution (best-effort)
-------------------------------------------------------------------------------

local function test_uncaught_raw_fiber_is_unscoped_by_default()
	-- Reset capture.
	unscoped.n = 0
	unscoped.last = nil

	local st, rep, body_val = scope_mod.run(function (_)
		runtime.spawn_raw(function ()
			error('raw-fiber-boom')
		end)
		runtime.yield()
		return 'ok'
	end)

	-- Contract: raw fibers are not scope-attributed, so they do not fail the scope.
	assert(st == 'ok' and body_val == 'ok', 'parent scope should remain ok when a raw fiber errors')
	assert_is_report(rep, 'report must be present')

	-- But the unscoped handler must see the error.
	assert(unscoped.n >= 1, 'unscoped handler should observe the raw fiber error')
	assert_contains(tostring(unscoped.last), 'raw-fiber-boom', 'unscoped error should include raw-fiber-boom')
end

-------------------------------------------------------------------------------
-- Suite entry
-------------------------------------------------------------------------------

local function run_all_tests()
	test_outside_fiber_current_is_root()

	test_current_scope_run_restores()
	test_structural_lifetime_children_joined_in_order()

	test_admission_close_and_close_op_idempotent()
	test_cancel_and_cancel_op_idempotent()

	test_cancellation_sentinel_and_try_semantics()
	test_fail_fast_and_siblings_observe_failed()
	test_failure_precedes_cancellation()

	test_fault_ops_and_not_ok_precedence()

	test_finalisers_lifo_and_join_non_interruptible()
	test_cancel_sentinel_in_finaliser_becomes_fault()

	test_reports_nested_children_depth_two()

	test_join_closes_admission_and_rejects_new_work()

	test_run_op_basic_and_failure_confinement()
	test_run_op_abort_on_choice_loss()
	test_run_op_parent_closed_before_start_is_cancelled()

	test_uncaught_raw_fiber_is_unscoped_by_default()
end

-------------------------------------------------------------------------------
-- Main
-------------------------------------------------------------------------------

run_in_root(function ()
	io.stdout:write('Running revised scope tests...\n')
	run_all_tests()
	io.stdout:write('OK\n')
end)

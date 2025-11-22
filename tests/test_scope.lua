--- Tests the Scope implementation.
print("test: fibers.scope")

-- look one level up
package.path = "../src/?.lua;" .. package.path

local runtime   = require "fibers.runtime"
local scope     = require "fibers.scope"
local op        = require "fibers.op"
local performer = require "fibers.performer"
local cond_mod  = require "fibers.cond"

-------------------------------------------------------------------------------
-- 1. Structural tests
-------------------------------------------------------------------------------

local function test_outside_fibers()
    local root = scope.root()

    -- current() outside any fibre should be the root (process-wide current scope)
    assert(scope.current() == root, "outside fibres, current() should be root")

    local outer_scope
    local inner_scope

    local st, err = scope.run(function(s)
        outer_scope = s

        -- Inside run, current() should be this child scope
        assert(scope.current() == s, "inside scope.run, current() should be child scope")
        assert(s:parent() == root, "outer scope parent must be root")

        -- root should see this child in its children list
        local rc = root:children()
        local found_outer = false
        for _, c in ipairs(rc) do
            if c == s then
                found_outer = true
                break
            end
        end
        assert(found_outer, "root:children() should contain outer scope")

        -- Nested run creates a grandchild of s
        local st2, err2 = scope.run(function(child2)
            inner_scope = child2
            assert(scope.current() == child2, "inside nested run, current() should be nested child")
            assert(child2:parent() == s, "nested scope parent must be outer scope")

            local sc = s:children()
            local found_inner = false
            for _, c in ipairs(sc) do
                if c == child2 then
                    found_inner = true
                    break
                end
            end
            assert(found_inner, "outer scope children() should contain nested scope")
        end)

        assert(st2 == "ok" and err2 == nil,
               "nested scope.run should complete with status ok")

        -- After nested run, current() should be back to the outer scope
        assert(scope.current() == s, "after nested run, current() should be outer scope again")
    end)

    assert(st == "ok" and err == nil, "outer scope.run should complete with status ok")

    assert(outer_scope ~= nil, "outer_scope should have been set")
    assert(inner_scope ~= nil, "inner_scope should have been set")
    assert(outer_scope ~= inner_scope, "outer and inner scopes must differ")

    -- After scope.run returns, current() outside fibres should be root again
    assert(scope.current() == scope.root(), "after scope.run, current() should be root outside fibres")
end

local function test_inside_fibers()
    local root = scope.root()

    local child_in_fiber
    local grandchild_in_fiber

    -- Use a cond to wait for the spawned fibre to finish.
    local done = cond_mod.new()

    -- Spawn a fibre anchored to the root scope.
    root:spawn(function(s)
        -- In this fibre, s is the scope used for spawn -> root
        assert(s == root, "spawn(fn) on root should pass root as scope")
        assert(scope.current() == root, "inside spawned fibre, current() should be root initially")

        -- Create a child scope inside the fibre
        local st, err = scope.run(function(child)
            child_in_fiber = child
            assert(scope.current() == child, "inside scope.run in fibre, current() should be child")
            assert(child:parent() == root, "child-in-fibre parent must be root")

            -- Create a grandchild scope
            local st2, err2 = scope.run(function(grandchild)
                grandchild_in_fiber = grandchild
                assert(scope.current() == grandchild, "inside nested run in fibre, current() should be grandchild")
                assert(grandchild:parent() == child, "grandchild parent must be child")
            end)

            assert(st2 == "ok" and err2 == nil,
                   "nested scope.run in fibre should complete with status ok")

            -- After nested run, current() should be back to child
            assert(scope.current() == child, "after nested run in fibre, current() should be child again")
        end)

        assert(st == "ok" and err == nil,
               "scope.run in fibre should complete with status ok")

        -- After inner run, current() should be back to root for this fibre
        assert(scope.current() == root, "after scope.run in fibre, current() should be root again")

        done:signal()
    end)

    -- Drive until the child fibre finishes.
    performer.perform(done:wait_op())

    -- After that, we are still inside the test fibre; current() should be root.
    assert(scope.current() == root, "after inner fibre completes, current() should be root in test fibre")

    -- Check that scopes created inside the fibre were recorded
    assert(child_in_fiber ~= nil, "child_in_fiber should have been set")
    assert(grandchild_in_fiber ~= nil, "grandchild_in_fiber should have been set")
    assert(child_in_fiber:parent() == root, "child_in_fiber parent must be root")
    assert(grandchild_in_fiber:parent() == child_in_fiber, "grandchild_in_fiber parent must be child_in_fiber")

    -- Check that root children include the child created in this fibre.
    local rc = root:children()
    local found_child = false
    for _, s in ipairs(rc) do
        if s == child_in_fiber then
            found_child = true
            break
        end
    end
    assert(found_child, "root:children() should contain child_in_fiber")
end

-------------------------------------------------------------------------------
-- 1b. basic scope.with_ev behaviour
-------------------------------------------------------------------------------

local function test_with_ev_basic()
    local parent = scope.current()
    local child_scope

    local ev = scope.with_ev(function(child)
        child_scope = child
        -- inside build_ev, current scope should be the child
        assert(scope.current() == child, "inside with_ev build_ev, current() should be child scope")
        assert(child:parent() == parent, "with_ev child parent should be current scope")

        -- simple event that returns two values
        return op.always(true):wrap(function()
            return 99, "ok"
        end)
    end)

    local a, b = performer.perform(ev)
    assert(a == 99 and b == "ok", "with_ev should propagate child event results")

    assert(child_scope ~= nil, "with_ev should have created a child scope")
    local st, err = child_scope:status()
    assert(st == "ok" and err == nil, "with_ev child scope should end ok on success")
end

-------------------------------------------------------------------------------
-- 2. Status transitions for scope.run (success, failure, cancellation)
-------------------------------------------------------------------------------

local function test_run_success_and_failure()
    local root = scope.root()

    -- Success case: scope.run returns status ok and body results.
    local success_scope
    local st, err, a, b = scope.run(function(s)
        success_scope = s
        local st0, err0 = s:status()
        assert(st0 == "running" and err0 == nil, "inside body, status should be running")
        return 42, "x"
    end)

    assert(st == "ok" and err == nil,
           "scope.run should report status ok on success")
    assert(a == 42 and b == "x", "scope.run should return body results on success")

    local st_ok, err_ok = success_scope:status()
    assert(st_ok == "ok" and err_ok == nil, "successful scope should end with status ok and no error")
    assert(success_scope:parent() == root, "success scope parent should be root")

    -- Failure case: body error becomes scope failure; scope.run does not throw.
    -- local fail_scope
    local st_fail, err_fail = scope.run(function()
        -- fail_scope = s
        error("body failure")
    end)

    assert(st_fail == "failed", "scope.run should report status failed on body error")
    assert(err_fail ~= nil, "failed scope should have a primary error recorded")
    assert(tostring(err_fail):find("body failure", 1, true),
           "failed scope primary error should mention the body failure")
end

local function test_run_explicit_cancel()
    -- If the body explicitly cancels the scope, scope.run should
    -- report status 'cancelled' and the cancellation reason.
    local cancelled_scope
    local st, serr = scope.run(function(s)
        cancelled_scope = s
        s:cancel("stop here")
    end)

    assert(st == "cancelled", "scope.run should report cancelled when scope is cancelled inside body")
    assert(serr == "stop here", "cancelled scope error should be the cancellation reason")

    local st2, serr2 = cancelled_scope:status()
    assert(st2 == "cancelled", "cancelled scope should have status 'cancelled'")
    assert(serr2 == "stop here", "cancelled scope error should be the cancellation reason")
end

-------------------------------------------------------------------------------
-- 3. Defers: LIFO ordering and execution on failure
-------------------------------------------------------------------------------

local function test_defers_lifo_and_failure()
    local order = {}
    local scope_ref

    local st, serr = scope.run(function(s)
        scope_ref = s
        s:defer(function() table.insert(order, "first") end)
        s:defer(function() table.insert(order, "second") end)
        error("boom in body")
    end)

    assert(st == "failed", "scope.run should report failure when body errors")
    assert(tostring(serr):find("boom in body", 1, true),
           "primary error should mention the body error")

    local st2, serr2 = scope_ref:status()
    assert(st2 == "failed", "scope should be failed after body error")
    assert(tostring(serr2):find("boom in body", 1, true),
           "scope error should mention the body error")

    assert(#order == 2, "two defers should have run")
    assert(order[1] == "second" and order[2] == "first",
           "defers should run in LIFO order even on failure")
end

-------------------------------------------------------------------------------
-- 4. Scope:sync via performer.perform: failure and cancellation paths
-------------------------------------------------------------------------------

local function test_sync_wraps_event_failure()
    -- Event whose post-wrap raises: tests that scope sees failure.
    local ev = op.always(123):wrap(function(v)
        assert(v == 123, "inner always should pass its value")
        error("event post-wrap failure")
    end)

    local failed_scope
    local st, serr = scope.run(function(s)
        failed_scope = s
        -- This synchronisation will cause this fibre to fail;
        -- scope should record status 'failed'.
        performer.perform(ev)
    end)

    assert(st == "failed", "scope.run should report failure when event post-wrap fails")
    assert(tostring(serr):find("event post-wrap failure", 1, true),
           "scope error should mention the event failure")

    local st2, serr2 = failed_scope:status()
    assert(st2 == "failed", "scope should be failed after event failure")
    assert(tostring(serr2):find("event post-wrap failure", 1, true),
           "scope error should mention the event failure")
end

local function test_sync_respects_cancellation()
    -- Race a never-ready event against cancellation; cancellation should win
    -- and be reflected as (ok=false, reason, nil) at the event level, and
    -- as status 'cancelled' at the scope level.
    local ev = op.never()

    local cancelled_scope
    local st, serr, ok_ev, reason_ev = scope.run(function(s)
        cancelled_scope = s
        s:cancel("cancel before sync")

        local ok2, reason2 = performer.perform(ev)
        assert(ok2 == false, "performer.perform should return ok=false after cancellation")
        assert(reason2 == "cancel before sync",
               "performer.perform should return cancellation reason")
        return ok2, reason2
    end)

    assert(st == "cancelled", "scope should be cancelled")
    assert(serr == "cancel before sync", "cancellation reason should be preserved")

    assert(ok_ev == false, "scope.run should return the event ok flag from body")
    assert(reason_ev == "cancel before sync",
           "scope.run should return the cancellation reason from body")

    local st2, serr2 = cancelled_scope:status()
    assert(st2 == "cancelled", "cancelled_scope should be cancelled")
    assert(serr2 == "cancel before sync", "cancelled_scope error should be the cancellation reason")
end

-------------------------------------------------------------------------------
-- 5. join_ev and done_ev (on failed/cancelled scopes)
-------------------------------------------------------------------------------

local function test_join_and_done_events()
    -- Failed scope: body error.
    local failed_scope
    local st_fail, err_fail = scope.run(function(s)
        failed_scope = s
        error("join test failure")
    end)

    assert(st_fail == "failed", "failed scope.run should report failed")
    assert(tostring(err_fail):find("join test failure", 1, true),
           "failed scope error should mention the body failure")

    do
        local ev = failed_scope:join_ev()
        local st, jerr = performer.perform(ev)
        assert(st == "failed", "join_ev on failed scope should report 'failed'")
        assert(tostring(jerr):find("join test failure", 1, true),
               "join_ev error should mention the body failure")
    end

    do
        local ev = failed_scope:done_ev()
        local reason = performer.perform(ev)
        -- For a failed scope we also call cancel(error), so done_ev
        -- should be triggered and report the same error.
        assert(tostring(reason):find("join test failure", 1, true),
               "done_ev on failed scope should report the failure reason")
    end

    -- Cancelled scope (explicit cancel, not body error).
    local cancelled_scope
    local st_cancel, err_cancel = scope.run(function(s)
        cancelled_scope = s
        s:cancel("stop again")
    end)

    assert(st_cancel == "cancelled", "cancelled scope.run should report cancelled")
    assert(err_cancel == "stop again",
           "cancelled scope.run should report the cancellation reason")

    do
        local ev = cancelled_scope:join_ev()
        local st, jerr = performer.perform(ev)
        assert(st == "cancelled" and jerr == "stop again",
               "join_ev on cancelled scope should report 'cancelled' and reason")
    end

    do
        local ev = cancelled_scope:done_ev()
        local reason = performer.perform(ev)
        assert(reason == "stop again",
               "done_ev on cancelled scope should report cancellation reason")
    end
end

-------------------------------------------------------------------------------
-- 6. Fail-fast from child fibres (via performer.perform)
-------------------------------------------------------------------------------

local function test_fail_fast_from_child_fibre()
    -- local root = scope.root()
    local test_scope

    local st, serr = scope.run(function(s)
        test_scope = s

        -- Use a condition to ensure the child fibre runs before we exit the body.
        local cond = cond_mod.new()

        -- Spawn a child fibre that signals, then fails.
        s:spawn(function(_)
            cond:signal()
            error("child fibre failure")
        end)

        -- Wait for the cond via performer, so we do not exit
        -- the body until after the child has signalled.
        performer.perform(cond:wait_op())
    end)

    assert(st == "failed", "scope.run should report failed when a child fibre fails")
    assert(tostring(serr):find("child fibre failure", 1, true),
           "primary error should mention child fibre failure")

    local st2, serr2 = test_scope:status()
    assert(st2 == "failed", "scope status should be failed after child fibre failure")
    assert(tostring(serr2):find("child fibre failure", 1, true),
           "scope primary error should mention child fibre failure")
end

-------------------------------------------------------------------------------
-- Main
-------------------------------------------------------------------------------

local function main()
    io.stdout:write("Running scope tests...\n")

    -- Run all tests inside a single top-level fibre so that scope.run
    -- and performer.perform are always called from within the scheduler.
    runtime.spawn_raw(function()
        test_outside_fibers()
        test_inside_fibers()
        test_with_ev_basic()
        test_run_success_and_failure()
        test_run_explicit_cancel()
        test_defers_lifo_and_failure()
        test_sync_wraps_event_failure()
        test_sync_respects_cancellation()
        test_join_and_done_events()
        test_fail_fast_from_child_fibre()
        io.stdout:write("OK\n")
        runtime.stop()
    end)

    runtime.main()
end

main()

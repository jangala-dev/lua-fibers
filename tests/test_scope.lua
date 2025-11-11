--- Tests the Scope implementation.
print("test: fibers.scope")

-- look one level up
package.path = "../src/?.lua;" .. package.path

local runtime   = require "fibers.runtime"
local scope     = require "fibers.scope"
local op        = require "fibers.op"
local performer = require "fibers.performer"

-------------------------------------------------------------------------------
-- 1. Structural tests (your originals, lightly generalised)
-------------------------------------------------------------------------------

local function test_outside_fibers()
    local root = scope.root()

    -- current() outside any fiber should be the root (process-wide current scope)
    assert(scope.current() == root, "outside fibers, current() should be root")

    local outer_scope
    local inner_scope

    scope.run(function(s)
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
        scope.run(function(child2)
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

        -- After nested run, current() should be back to the outer scope
        assert(scope.current() == s, "after nested run, current() should be outer scope again")
    end)

    assert(outer_scope ~= nil, "outer_scope should have been set")
    assert(inner_scope ~= nil, "inner_scope should have been set")
    assert(outer_scope ~= inner_scope, "outer and inner scopes must differ")

    -- After scope.run returns, current() outside fibers should be root again
    assert(scope.current() == scope.root(), "after scope.run, current() should be root outside fibers")
end

local function test_inside_fibers()
    local root = scope.root()

    local child_in_fiber
    local grandchild_in_fiber

    -- Spawn a fiber anchored to the root scope.
    root:spawn(function(s)
        -- In this fiber, s is the scope used for spawn -> root
        assert(s == root, "spawn(fn) on root should pass root as scope")
        assert(scope.current() == root, "inside spawned fiber, current() should be root initially")

        -- Create a child scope inside the fiber
        scope.run(function(child)
            child_in_fiber = child
            assert(scope.current() == child, "inside scope.run in fiber, current() should be child")
            assert(child:parent() == root, "child-in-fiber parent must be root")

            -- Create a grandchild scope
            scope.run(function(grandchild)
                grandchild_in_fiber = grandchild
                assert(scope.current() == grandchild, "inside nested run in fiber, current() should be grandchild")
                assert(grandchild:parent() == child, "grandchild parent must be child")
            end)

            -- After nested run, current() should be back to child
            assert(scope.current() == child, "after nested run in fiber, current() should be child again")
        end)

        -- After inner run, current() should be back to root for this fiber
        assert(scope.current() == root, "after scope.run in fiber, current() should be root again")

        -- Stop the scheduler once all fiber-local tests have run
        runtime.stop()
    end)

    -- Drive the scheduler so the spawned fiber runs
    runtime.main()

    -- After main() returns we are back outside fibers;
    -- current() should again be the process-wide current scope (root).
    assert(scope.current() == root, "after runtime.main, current() outside fibers should be root")

    -- Check that scopes created inside the fiber were recorded
    assert(child_in_fiber ~= nil, "child_in_fiber should have been set")
    assert(grandchild_in_fiber ~= nil, "grandchild_in_fiber should have been set")
    assert(child_in_fiber:parent() == root, "child_in_fiber parent must be root")
    assert(grandchild_in_fiber:parent() == child_in_fiber, "grandchild_in_fiber parent must be child_in_fiber")

    -- Check that root children include the child created in this fiber.
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
-- 1b. New: basic scope.with_ev behaviour
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

    local a, b = op.perform(ev)
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

    -- Success case: scope.run returns body results, status becomes "ok".
    local success_scope
    local a, b = scope.run(function(s)
        success_scope = s
        local st, err = s:status()
        assert(st == "running" and err == nil, "inside body, status should be running")
        return 42, "x"
    end)

    assert(a == 42 and b == "x", "scope.run should return body results on success")
    local st_ok, err_ok = success_scope:status()
    assert(st_ok == "ok" and err_ok == nil, "successful scope should end with status ok and no error")
    assert(success_scope:parent() == root, "success scope parent should be root")

    -- Failure case: body error propagates, status becomes "failed".
    local fail_scope
    local ok = pcall(function()
        scope.run(function(s)
            fail_scope = s
            error("body failure")
        end)
    end)
    assert(not ok, "scope.run should rethrow body error on failure")
    local st_fail, err_fail = fail_scope:status()
    assert(st_fail == "failed", "failed scope should have status 'failed'")
    assert(type(err_fail) == "string" or err_fail ~= nil,
           "failed scope should have a primary error recorded")
    assert(tostring(err_fail):find("body failure", 1, true),
           "failed scope primary error should mention the body failure")
end

local function test_run_explicit_cancel()
    -- If the body explicitly cancels the scope, scope.run should raise
    -- the cancellation reason and status should be "cancelled".
    local cancelled_scope
    local ok = pcall(function()
        scope.run(function(s)
            cancelled_scope = s
            s:cancel("stop here")
        end)
    end)
    assert(not ok, "scope.run should raise when scope is cancelled inside body")
    local st, serr = cancelled_scope:status()
    assert(st == "cancelled", "cancelled scope should have status 'cancelled'")
    assert(serr == "stop here", "cancelled scope error should be the cancellation reason")
end

-------------------------------------------------------------------------------
-- 3. Defers: LIFO ordering and execution on failure
-------------------------------------------------------------------------------

local function test_defers_lifo_and_failure()
    local order = {}
    local scope_ref

    local ok = pcall(function()
        scope.run(function(s)
            scope_ref = s
            s:defer(function() table.insert(order, "first") end)
            s:defer(function() table.insert(order, "second") end)
            error("boom in body")
        end)
    end)

    assert(not ok, "scope.run should propagate body failure")
    local st, serr = scope_ref:status()
    assert(st == "failed", "scope should be failed after body error")
    assert(tostring(serr):find("boom in body", 1, true),
           "primary error should mention the body error")
    assert(#order == 2, "two defers should have run")
    assert(order[1] == "second" and order[2] == "first",
           "defers should run in LIFO order even on failure")
end

-------------------------------------------------------------------------------
-- 4. Scope:sync via performer.perform: failure and cancellation paths
-------------------------------------------------------------------------------

local function test_sync_wraps_event_failure()
    -- Event whose post-wrap raises: tests wrap_failure path.
    local ev = op.always(123):wrap(function(v)
        assert(v == 123, "inner always should pass its value")
        error("event post-wrap failure")
    end)

    local failed_scope
    local ok = pcall(function()
        scope.run(function(s)
            failed_scope = s
            -- This synchronisation should trigger fail-fast handling via performer.
            performer.perform(ev)
        end)
    end)

    assert(not ok, "performer.perform on failing event should raise")
    local st, serr = failed_scope:status()
    assert(st == "failed", "scope should be failed after event failure")
    assert(tostring(serr):find("event post-wrap failure", 1, true),
           "scope error should mention the event failure")
end

local function test_sync_respects_cancellation()
    -- Race a never-ready event against cancellation.
    local ev = op.never()

    local cancelled_scope
    local ok = pcall(function()
        scope.run(function(s)
            cancelled_scope = s
            s:cancel("cancel before sync")
            -- This should immediately raise via the cancellation event,
            -- rather than blocking on never().
            performer.perform(ev)
        end)
    end)

    assert(not ok, "performer.perform on never() after cancel should raise")
    local st, serr = cancelled_scope:status()
    assert(st == "cancelled", "scope should be cancelled")
    assert(serr == "cancel before sync", "cancellation reason should be preserved")
end

-------------------------------------------------------------------------------
-- 5. join_ev and done_ev (on failed/cancelled scopes)
-------------------------------------------------------------------------------

local function test_join_and_done_events()
    -- Failed scope: body error.
    local failed_scope
    local ok_fail = pcall(function()
        scope.run(function(s)
            failed_scope = s
            error("join test failure")
        end)
    end)
    assert(not ok_fail, "failed scope.run should raise")

    do
        local ev = failed_scope:join_ev()
        local st, jerr = op.perform(ev)
        assert(st == "failed", "join_ev on failed scope should report 'failed'")
        assert(tostring(jerr):find("join test failure", 1, true),
               "join_ev error should mention the body failure")
    end

    do
        local ev = failed_scope:done_ev()
        local reason = op.perform(ev)
        -- For a failed scope we also call cancel(error), so done_ev
        -- should be triggered and report the same error.
        assert(tostring(reason):find("join test failure", 1, true),
               "done_ev on failed scope should report the failure reason")
    end

    -- Cancelled scope (explicit cancel, not body error).
    local cancelled_scope
    local ok_cancel = pcall(function()
        scope.run(function(s)
            cancelled_scope = s
            s:cancel("stop again")
        end)
    end)
    assert(not ok_cancel, "cancelled scope.run should raise")

    do
        local ev = cancelled_scope:join_ev()
        local st, jerr = op.perform(ev)
        assert(st == "cancelled" and jerr == "stop again",
               "join_ev on cancelled scope should report 'cancelled' and reason")
    end

    do
        local ev = cancelled_scope:done_ev()
        local reason = op.perform(ev)
        assert(reason == "stop again",
               "done_ev on cancelled scope should report cancellation reason")
    end
end

-------------------------------------------------------------------------------
-- 6. Fail-fast from child fibres (via performer.perform)
-------------------------------------------------------------------------------

local function test_fail_fast_from_child_fibre()
    local root = scope.root()
    local test_scope

    root:spawn(function()
        -- Create a child scope under root in this fibre.
        local ok = pcall(function()
            scope.run(function(s)
                test_scope = s

                -- Use a condition to ensure the child fibre runs before we exit the body.
                local cond = op.new_cond()

                -- Spawn a child fibre that signals, then fails.
                s:spawn(function(_)
                    cond.signal()
                    error("child fibre failure")
                end)

                -- Wait for the cond via performer, so we do not exit
                -- the body until after the child has signalled.
                performer.perform(cond.wait_op())
            end)
        end)

        assert(not ok, "scope.run should raise when a child fibre fails")
        local st, serr = test_scope:status()
        assert(st == "failed", "scope status should be failed after child fibre failure")
        assert(tostring(serr):find("child fibre failure", 1, true),
               "primary error should mention child fibre failure")

        runtime.stop()
    end)

    runtime.main()
end

-------------------------------------------------------------------------------
-- Main
-------------------------------------------------------------------------------

local function main()
    io.stdout:write("Running scope tests...\n")
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
end

main()

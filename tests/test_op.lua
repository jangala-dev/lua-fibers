-- fibers/op comprehensive test
print("testing: fibers.op (CML events)")

-- look one level up
package.path = "../?.lua;" .. package.path

local op     = require 'fibers.op'
local fiber = require 'fibers.fiber'

------------------------------------------------------------
-- Helpers
------------------------------------------------------------

-- Ready primitive event that returns val.
local function task(val)
    local wrap_fn  = function(x) return x end
    local try_fn   = function() return true, val end
    local block_fn = function() end
    return op.new_base_op(wrap_fn, try_fn, block_fn)
end

-- Primitive that never becomes ready (try=false, no block).
local function never_op()
    local wrap_fn  = function(x) return x end
    local try_fn   = function() return false end
    local block_fn = function() end
    return op.new_base_op(wrap_fn, try_fn, block_fn)
end

-- Primitive that *forces* the blocking path then completes once.
local function async_task(val)
    local tries = 0
    local function try_fn()
        tries = tries + 1
        return false
    end
    local function block_fn(suspension, wrap_fn)
        -- Complete on next scheduler turn.
        local t = suspension:complete_task(wrap_fn, val)
        suspension.sched:schedule(t)
    end
    local ev = op.new_base_op(nil, try_fn, block_fn)
    return ev, function() return tries end
end

------------------------------------------------------------
-- Run all tests inside a single top-level fiber
------------------------------------------------------------

fiber.spawn(function()

    --------------------------------------------------------
    -- 1) Base op: perform, perform_alt
    --------------------------------------------------------
    do
        local base = task(1)
        assert(base:perform() == 1, "base: perform failed")

        local base2 = task(2)
        assert(base2:perform_alt(function() return 9 end) == 2,
            "base: perform_alt should use event result")

        local never = never_op()
        assert(never:perform_alt(function() return 99 end) == 99,
            "base: perform_alt should use fallback when not ready")
    end

    --------------------------------------------------------
    -- 2) Blocking path: async_task
    --------------------------------------------------------
    do
        local ev, tries = async_task(42)
        local v = ev:perform()
        assert(v == 42, "async_task: wrong result")
        assert(tries() == 1, "async_task: try_fn not called exactly once")
    end

    --------------------------------------------------------
    -- 3) Choice over multiple ready events
    -- (we don't assume fairness, only that results are valid)
    --------------------------------------------------------
    do
        local choice_ev = op.choice(task(1), task(2), task(3))
        for _ = 1, 5 do
            local v = choice_ev:perform()
            assert(v == 1 or v == 2 or v == 3,
                "choice(ready): result not in {1,2,3}")
        end
    end

    --------------------------------------------------------
    -- 4) Wrap (including nested and on choice)
    --------------------------------------------------------
    do
        -- wrap on choice
        local ev = op.choice(task(1), task(2)):wrap(function(x)
            return x * 10
        end)
        local v = ev:perform()
        assert(v == 10 or v == 20, "wrap(choice): wrong result")

        -- nested wrap: ((x + 1) * 2)
        local ev2 = task(5)
            :wrap(function(x) return x + 1 end)
            :wrap(function(y) return y * 2 end)
        local v2 = ev2:perform()
        assert(v2 == 12, "nested wrap: wrong result")
    end

    --------------------------------------------------------
    -- 5) Guard: basic, in choice, nested, perform_alt
    --------------------------------------------------------
    do
        -- basic
        local calls = 0
        local g = function()
            calls = calls + 1
            return task(42)
        end
        local ev = op.guard(g)
        local v = ev:perform()
        assert(v == 42, "guard basic: wrong result")
        assert(calls == 1, "guard basic: builder not called once")

        -- guard inside choice
        local calls2 = 0
        local g2 = function()
            calls2 = calls2 + 1
            return task(10)
        end
        local guarded = op.guard(g2)
        local choice_ev = op.choice(guarded, task(20))
        local runs = 5
        for _ = 1, runs do
            local r = choice_ev:perform()
            assert(r == 10 or r == 20,
                "guard in choice: result not in {10,20}")
        end
        assert(calls2 == runs, "guard in choice: builder call mismatch")

        -- guard + wrap
        local calls3 = 0
        local g3 = function()
            calls3 = calls3 + 1
            return task(5)
        end
        local ev3 = op.guard(g3):wrap(function(x) return x * 2 end)
        local v3 = ev3:perform()
        assert(v3 == 10, "guard wrap: wrong result")
        assert(calls3 == 1, "guard wrap: builder not called once")

        -- guard + perform_alt (inner not ready)
        local calls4 = 0
        local g4 = function()
            calls4 = calls4 + 1
            return never_op()
        end
        local ev4 = op.guard(g4)
        local v4 = ev4:perform_alt(function() return 99 end)
        assert(v4 == 99, "guard perform_alt: wrong fallback")
        assert(calls4 == 1, "guard perform_alt: builder not called once")

        -- nested guards
        local outer_calls, inner_calls = 0, 0
        local inner_g = function()
            inner_calls = inner_calls + 1
            return task(7)
        end
        local outer_g = function()
            outer_calls = outer_calls + 1
            return op.guard(inner_g)
        end
        local ev5 = op.guard(outer_g):wrap(function(x) return x + 1 end)
        local v5 = ev5:perform()
        assert(v5 == 8, "nested guard: wrong result")
        assert(outer_calls == 1, "nested guard: outer builder count")
        assert(inner_calls == 1, "nested guard: inner builder count")
    end

    --------------------------------------------------------
    -- 6) poll() and perform_alt() on composite events
    --------------------------------------------------------
    do
        -- poll on ready event
        local ok, v = task(123):poll()
        assert(ok and v == 123, "poll(ready): wrong result")

        -- poll on never-ready
        local ok2, v2 = never_op():poll()
        assert(ok2 == false and v2 == nil, "poll(never): expected (false)")

        -- poll on composite none-ready
        local comp = op.choice(never_op(), never_op())
        local ok3, v3 = comp:poll()
        assert(ok3 == false and v3 == nil, "poll(composite none): expected (false)")

        -- perform_alt on composite (ready)
        local comp_ready = op.choice(task(1), task(2))
        local r1 = comp_ready:perform_alt(function() return 99 end)
        assert(r1 == 1 or r1 == 2,
            "perform_alt(composite ready): wrong result")

        -- perform_alt on composite (none ready)
        local comp_never = op.choice(never_op(), never_op())
        local r2 = comp_never:perform_alt(function() return 42 end)
        assert(r2 == 42, "perform_alt(composite none): fallback not used")
    end

    --------------------------------------------------------
    -- 7) with_nack: winner vs loser vs poll, plus guard+with_nack
    --------------------------------------------------------
    do
        -- 7.1 with_nack branch wins: nack must NOT fire
        do
            local cancelled = false
            local with_nack_ev = op.with_nack(function(nack_ev)
                fiber.spawn(function()
                    nack_ev:perform()
                    cancelled = true
                end)
                return task("WIN")
            end)

            -- opposing arm never ready
            local ev = op.choice(with_nack_ev, never_op())
            local v = ev:perform()
            assert(v == "WIN", "with_nack win: wrong winner")

            fiber.yield()
            assert(cancelled == false, "with_nack win: nack fired unexpectedly")
        end

        -- 7.2 with_nack branch loses: nack MUST fire
        do
            local cancelled = false
            local with_nack_ev = op.with_nack(function(nack_ev)
                fiber.spawn(function()
                    nack_ev:perform()
                    cancelled = true
                end)
                return never_op()
            end)

            local ev = op.choice(with_nack_ev, task("OTHER"))
            local v = ev:perform()
            assert(v == "OTHER", "with_nack loss: wrong winner")

            fiber.yield()
            assert(cancelled == true, "with_nack loss: nack did not fire")
        end

        -- 7.3 with_nack + poll(): some arm ready → nack fires for loser
        do
            local cancelled = false
            local with_nack_ev = op.with_nack(function(nack_ev)
                fiber.spawn(function()
                    nack_ev:perform()
                    cancelled = true
                end)
                return never_op()
            end)

            local ev = op.choice(with_nack_ev, task("WINNER"))
            local ok, v = ev:poll()
            assert(ok and v == "WINNER", "with_nack+poll: wrong result")

            fiber.yield()
            assert(cancelled == true, "with_nack+poll: nack not fired")
        end

        -- 7.4 with_nack + poll(): no arm ready → NO commit, NO nack
        do
            local cancelled = false
            local with_nack_ev = op.with_nack(function(nack_ev)
                fiber.spawn(function()
                    nack_ev:perform()
                    cancelled = true
                end)
                return never_op()
            end)

            local ev = op.choice(with_nack_ev, never_op())
            local ok, v = ev:poll()
            assert(ok == false and v == nil,
                "with_nack+poll(no ready): expected no commit")

            fiber.yield()
            assert(cancelled == false,
                "with_nack+poll(no ready): nack fired unexpectedly")
        end

        -- 7.5 guard + with_nack interaction
        do
            local guard_calls = 0
            local cancelled   = false

            local guarded     = op.guard(function()
                guard_calls = guard_calls + 1
                return op.with_nack(function(nack_ev)
                    fiber.spawn(function()
                        nack_ev:perform()
                        cancelled = true
                    end)
                    return never_op()
                end)
            end)

            local ev          = op.choice(guarded, task("OK"))
            local v           = ev:perform()
            assert(v == "OK", "guard+with_nack: wrong winner")

            fiber.yield()
            assert(cancelled == true, "guard+with_nack: nack not fired")
            assert(guard_calls == 1, "guard+with_nack: builder not once")
        end
    end

    --------------------------------------------------------
    -- 8) Nested with_nack trees
    --------------------------------------------------------
    do
        -- 8.1 winner has BOTH outer and inner with_nack:
        --     neither outer nor inner nack should fire.
        do
            local outer_cancelled, inner_cancelled = false, false

            local outer = op.with_nack(function(outer_nack_ev)
                -- watcher for outer nack
                fiber.spawn(function()
                    outer_nack_ev:perform()
                    outer_cancelled = true
                end)

                -- inner with_nack subtree
                return op.with_nack(function(inner_nack_ev)
                    -- watcher for inner nack
                    fiber.spawn(function()
                        inner_nack_ev:perform()
                        inner_cancelled = true
                    end)
                    -- this leaf *wins*, so both nacks are on the winner path
                    return task("INNER_WIN")
                end)
            end)

            -- Only competitor is never_ready, so outer subtree wins.
            local ev = op.choice(outer, never_op())
            local v = ev:perform()
            assert(v == "INNER_WIN",
                   "nested with_nack (inner winner): wrong result")

            fiber.yield()
            assert(outer_cancelled == false,
                   "nested with_nack (inner winner): outer nack fired unexpectedly")
            assert(inner_cancelled == false,
                   "nested with_nack (inner winner): inner nack fired unexpectedly")
        end

        -- 8.2 winner is in OUTER subtree but NOT in inner subtree:
        --     outer nack must NOT fire, inner nack MUST fire.
        do
            local outer_cancelled, inner_cancelled = false, false

            local outer = op.with_nack(function(outer_nack_ev)
                fiber.spawn(function()
                    outer_nack_ev:perform()
                    outer_cancelled = true
                end)

                return op.choice(
                    -- This leaf wins: path has ONLY outer's nack.
                    task("OUTER_ONLY"),
                    -- This leaf loses: path has OUTER and INNER nacks.
                    op.with_nack(function(inner_nack_ev)
                        fiber.spawn(function()
                            inner_nack_ev:perform()
                            inner_cancelled = true
                        end)
                        return never_op()
                    end)
                )
            end)

            local ev = op.choice(outer, never_op())
            local v = ev:perform()
            assert(v == "OUTER_ONLY",
                   "nested with_nack (outer-only winner): wrong result")

            fiber.yield()
            assert(outer_cancelled == false,
                   "nested with_nack (outer-only winner): outer nack fired unexpectedly")
            assert(inner_cancelled == true,
                   "nested with_nack (outer-only winner): inner nack did not fire")
        end

        -- 8.3 winner is OUTSIDE the outer with_nack subtree:
        --     both outer and inner nacks MUST fire.
        do
            local outer_cancelled, inner_cancelled = false, false

            local outer = op.with_nack(function(outer_nack_ev)
                fiber.spawn(function()
                    outer_nack_ev:perform()
                    outer_cancelled = true
                end)

                -- Entire outer subtree never becomes ready.
                return op.with_nack(function(inner_nack_ev)
                    fiber.spawn(function()
                        inner_nack_ev:perform()
                        inner_cancelled = true
                    end)
                    return never_op()
                end)
            end)

            -- Top-level winner is outside the outer subtree.
            local ev = op.choice(outer, task("TOP_WIN"))
            local v = ev:perform()
            assert(v == "TOP_WIN",
                   "nested with_nack (outer loses): wrong winner")

            fiber.yield()
            assert(outer_cancelled == true,
                   "nested with_nack (outer loses): outer nack did not fire")
            assert(inner_cancelled == true,
                   "nested with_nack (outer loses): inner nack did not fire")
        end
    end

    print("fibers.op tests: ok")
    fiber.stop()
end)

fiber.main()

-- fibers/op compact but comprehensive test (no poll)
print("testing: fibers.op")

-- look one level up
package.path = "../?.lua;" .. package.path

local op    = require 'fibers.op'
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
    -- 1) Base op: perform, perform_alt, wrap
    --------------------------------------------------------
    do
        local base = task(1)
        assert(base:perform() == 1, "base: perform failed")

        -- perform_alt: event wins, fallback ignored
        local base2 = task(2)
        local palt1 = base2:perform_alt(function() return 9 end)
        assert(palt1 == 2, "base: perform_alt should use event result")

        -- perform_alt: never-ready event → fallback wins
        local never = never_op()
        local palt2 = never:perform_alt(function() return 99 end)
        assert(palt2 == 99, "base: perform_alt should use fallback when event can't commit")

        -- perform_alt: async event should still win (gets a chance next turn)
        do
            local won
            local fallback_called = false
            local ev, tries = async_task(123)
            local r = ev:perform_alt(function()
                fallback_called = true
                return -1
            end)
            won = (r == 123)
            assert(won, "perform_alt(async): expected main event to win")
            assert(tries() == 1, "async_task: try_fn not called exactly once")
            assert(fallback_called == false,
                "perform_alt(async): fallback should not run when event commits")
        end

        -- nested wrap: ((x + 1) * 2)
        local ev2 = task(5)
            :wrap(function(x) return x + 1 end)
            :wrap(function(y) return y * 2 end)
        local v2 = ev2:perform()
        assert(v2 == 12, "nested wrap: wrong result")
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
    -- 3) Choice + wrap
    --------------------------------------------------------
    do
        -- choice over multiple ready events
        local choice_ev = op.choice(task(1), task(2), task(3))
        for _ = 1, 5 do
            local v = choice_ev:perform()
            assert(v == 1 or v == 2 or v == 3,
                "choice(ready): result not in {1,2,3}")
        end

        -- wrap on choice
        local ev = op.choice(task(1), task(2)):wrap(function(x)
            return x * 10
        end)
        local v = ev:perform()
        assert(v == 10 or v == 20, "wrap(choice): wrong result")
    end

    --------------------------------------------------------
    -- 4) Guard: basic + in choice + with with_nack
    --------------------------------------------------------
    do
        -- basic guard
        local calls = 0
        local g = function()
            calls = calls + 1
            return task(42)
        end
        local ev = op.guard(g)
        local v = ev:perform()
        assert(v == 42, "guard basic: wrong result")
        assert(calls == 1, "guard basic: builder not called once")

        -- guard in choice (ensures builder runs each sync)
        local calls2 = 0
        local guarded = op.guard(function()
            calls2 = calls2 + 1
            return task(10)
        end)
        local choice_ev = op.choice(guarded, task(20))
        local runs = 5
        for _ = 1, runs do
            local r = choice_ev:perform()
            assert(r == 10 or r == 20,
                "guard in choice: result not in {10,20}")
        end
        assert(calls2 == runs, "guard in choice: builder call mismatch")

        -- guard + with_nack (builder returns a with_nack event)
        local guard_calls, cancelled = 0, false
        local guarded_nack = op.guard(function()
            guard_calls = guard_calls + 1
            return op.with_nack(function(nack_ev)
                fiber.spawn(function()
                    nack_ev:perform()
                    cancelled = true
                end)
                return never_op()
            end)
        end)

        local ev2 = op.choice(guarded_nack, task("OK"))
        local v2  = ev2:perform()
        assert(v2 == "OK", "guard+with_nack: wrong winner")

        fiber.yield()
        assert(cancelled == true, "guard+with_nack: nack not fired")
        assert(guard_calls == 1, "guard+with_nack: builder not once")
    end

    --------------------------------------------------------
    -- 5) perform_alt on composite events
    --------------------------------------------------------
    do
        -- composite ready: choice(task, task)
        local comp_ready = op.choice(task(1), task(2))
        local r1 = comp_ready:perform_alt(function() return 99 end)
        assert(r1 == 1 or r1 == 2,
            "perform_alt(composite ready): wrong result")

        -- composite never-ready: choice(never, never) → fallback
        local comp_never = op.choice(never_op(), never_op())
        local r2 = comp_never:perform_alt(function() return 42 end)
        assert(r2 == 42, "perform_alt(composite none): fallback not used")
    end

    --------------------------------------------------------
    -- 6) with_nack: winner vs loser, basic nesting
    --------------------------------------------------------
    do
        -- 6.1 with_nack branch wins: nack must NOT fire
        do
            local cancelled = false
            local with_nack_ev = op.with_nack(function(nack_ev)
                fiber.spawn(function()
                    nack_ev:perform()
                    cancelled = true
                end)
                return task("WIN")
            end)

            local ev = op.choice(with_nack_ev, never_op())
            local v  = ev:perform()
            assert(v == "WIN", "with_nack win: wrong winner")

            fiber.yield()
            assert(cancelled == false, "with_nack win: nack fired unexpectedly")
        end

        -- 6.2 with_nack branch loses: nack MUST fire
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
            local v  = ev:perform()
            assert(v == "OTHER", "with_nack loss: wrong winner")

            fiber.yield()
            assert(cancelled == true, "with_nack loss: nack did not fire")
        end

        -- 6.3 basic nested with_nack:
        --     outer subtree wins via inner leaf → neither nack fires.
        do
            local outer_cancelled, inner_cancelled = false, false

            local outer = op.with_nack(function(outer_nack_ev)
                fiber.spawn(function()
                    outer_nack_ev:perform()
                    outer_cancelled = true
                end)

                return op.with_nack(function(inner_nack_ev)
                    fiber.spawn(function()
                        inner_nack_ev:perform()
                        inner_cancelled = true
                    end)
                    return task("INNER_WIN")
                end)
            end)

            local ev = op.choice(outer, never_op())
            local v  = ev:perform()
            assert(v == "INNER_WIN",
                   "nested with_nack: wrong result")

            fiber.yield()
            assert(outer_cancelled == false,
                   "nested with_nack: outer nack fired unexpectedly")
            assert(inner_cancelled == false,
                   "nested with_nack: inner nack fired unexpectedly")
        end
    end

    --------------------------------------------------------
    -- 7) bracket: RAII-style resource management over events
    --------------------------------------------------------
    do
        ----------------------------------------------------
        -- 7.1 basic success: inner event wins → aborted=false
        ----------------------------------------------------
        do
            local acq_count = 0
            local rel_count = 0
            local use_count = 0
            local last_res, last_aborted

            local ev = op.bracket(
                function()
                    acq_count = acq_count + 1
                    return "RESOURCE"
                end,
                function(res, aborted)
                    rel_count    = rel_count + 1
                    last_res     = res
                    last_aborted = aborted
                end,
                function(res)
                    use_count = use_count + 1
                    assert(res == "RESOURCE", "bracket basic: wrong resource")
                    return task(99)
                end
            )

            local v = ev:perform()
            assert(v == 99, "bracket basic: wrong result")

            assert(acq_count == 1, "bracket basic: acquire not once")
            assert(use_count == 1, "bracket basic: use not once")
            assert(rel_count == 1, "bracket basic: release not once")
            assert(last_res == "RESOURCE", "bracket basic: wrong res in release")
            assert(last_aborted == false,
                "bracket basic: aborted flag should be false on success")
        end

        ----------------------------------------------------
        -- 7.2 losing branch in choice → aborted=true
        ----------------------------------------------------
        do
            local acq_count, use_count, rel_count = 0, 0, 0
            local last_aborted

            local bracket_ev = op.bracket(
                function()
                    acq_count = acq_count + 1
                    return "R"
                end,
                function(_, aborted)
                    rel_count    = rel_count + 1
                    last_aborted = aborted
                end,
                function(r)
                    use_count = use_count + 1
                    assert(r == "R")
                    return never_op()
                end
            )

            local ev = op.choice(bracket_ev, task("WIN"))
            local v  = ev:perform()
            assert(v == "WIN", "bracket choice: wrong winner")

            assert(acq_count == 1, "bracket choice: acquire not once")
            assert(use_count == 1, "bracket choice: use not once")
            assert(rel_count == 1, "bracket choice: release not once")
            assert(last_aborted == true,
                "bracket choice: aborted flag should be true when losing")
        end

        ----------------------------------------------------
        -- 7.3 bracket + perform_alt:
        --   bracket arm never commits → aborted=true, fallback used
        ----------------------------------------------------
        do
            local acq_count, use_count, rel_count = 0, 0, 0
            local last_aborted, fallback_called

            local bracket_ev = op.bracket(
                function()
                    acq_count = acq_count + 1
                    return "R"
                end,
                function(_, aborted)
                    rel_count    = rel_count + 1
                    last_aborted = aborted
                end,
                function(r)
                    use_count = use_count + 1
                    assert(r == "R")
                    return never_op()
                end
            )

            local res = bracket_ev:perform_alt(function()
                fallback_called = true
                return "FALLBACK"
            end)

            assert(res == "FALLBACK",
                "bracket+perform_alt: expected fallback result")
            assert(fallback_called == true,
                "bracket+perform_alt: fallback thunk not called")

            assert(acq_count == 1, "bracket+perform_alt: acquire once")
            assert(use_count == 1, "bracket+perform_alt: use once")
            assert(rel_count == 1, "bracket+perform_alt: release once")
            assert(last_aborted == true,
                "bracket+perform_alt: aborted flag should be true when losing")
        end
    end

    print("fibers.op tests: ok")
    fiber.stop()
end)

fiber.main()

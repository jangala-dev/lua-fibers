-- fibers/op compact but comprehensive test
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

        local base2 = task(2)
        assert(base2:perform_alt(function() return 9 end) == 2,
            "base: perform_alt should use event result")

        local never = never_op()
        assert(never:perform_alt(function() return 99 end) == 99,
            "base: perform_alt should use fallback when not ready")

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
    -- 5) poll() and perform_alt() on composite events
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
    -- 6) with_nack: winner vs loser, poll, basic nesting
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

        -- 6.3 with_nack + poll(): some arm ready → nack fires for loser
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

        -- 6.4 with_nack + poll(): no arm ready → NO commit, NO nack
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

        -- 6.5 basic nested with_nack:
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
        -- 7.3 bracket + poll:
        --   (a) other arm ready → aborted=true
        --   (b) no arm ready → NO release
        ----------------------------------------------------
        do
            -- (a) other arm ready
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

                local ev = op.choice(bracket_ev, task("WINNER"))
                local ok, v = ev:poll()
                assert(ok and v == "WINNER",
                    "bracket+poll (other ready): wrong result")

                assert(acq_count == 1, "bracket+poll (other ready): acquire once")
                assert(use_count == 1, "bracket+poll (other ready): use once")
                assert(rel_count == 1, "bracket+poll (other ready): release once")
                assert(last_aborted == true,
                    "bracket+poll (other ready): aborted flag should be true")
            end

            -- (b) none ready → no commit → no release
            do
                local acq_count, use_count, rel_count = 0, 0, 0

                local bracket_ev = op.bracket(
                    function()
                        acq_count = acq_count + 1
                        return "R"
                    end,
                    function(_, _)
                        rel_count = rel_count + 1
                    end,
                    function(r)
                        use_count = use_count + 1
                        assert(r == "R")
                        return never_op()
                    end
                )

                local ev = op.choice(bracket_ev, never_op())
                local ok, v = ev:poll()
                assert(ok == false and v == nil,
                    "bracket+poll (none ready): expected (false)")

                assert(acq_count == 1, "bracket+poll (none ready): acquire once")
                assert(use_count == 1, "bracket+poll (none ready): use once")
                assert(rel_count == 0,
                    "bracket+poll (none ready): release should NOT run without commit")
            end
        end
    end

    print("fibers.op tests: ok")
    fiber.stop()
end)

fiber.main()

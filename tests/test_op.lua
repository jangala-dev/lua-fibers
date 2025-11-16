-- fibers/op compact but comprehensive test (no poll)
print("testing: fibers.op")

-- look one level up
package.path = "../src/?.lua;" .. package.path

local op      = require 'fibers.op'
local runtime = require 'fibers.runtime'

local perform, choice = require 'fibers.performer'.perform, op.choice
local always  = op.always
local never   = op.never

------------------------------------------------------------
-- Helpers
------------------------------------------------------------

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
    local ev = op.new_primitive(nil, try_fn, block_fn)
    return ev, function() return tries end
end

------------------------------------------------------------
-- Run all tests inside a single top-level fiber
------------------------------------------------------------

runtime.spawn(function()

    --------------------------------------------------------
    -- 1) Base event: perform, or_else, wrap
    --------------------------------------------------------
    do
        local base = always(1)
        assert(perform(base) == 1, "base: perform failed")

        -- or_else: event wins, fallback ignored
        local base2  = always(2)
        local ev1    = base2:or_else(function() return 9 end)
        local palt1  = perform(ev1)
        assert(palt1 == 2, "base: or_else should use event result")

        -- or_else: never-ready event → fallback wins
        local ev2   = never():or_else(function() return 99 end)
        local palt2 = perform(ev2)
        assert(palt2 == 99, "base: or_else should use fallback when event can't commit")

        -- or_else: async event is not ready now, so fallback wins
        do
            local fallback_called = false
            local ev_async, tries = async_task(123)
            local ev = ev_async:or_else(function()
                fallback_called = true
                return -1
            end)
            local r = perform(ev)

            assert(r == -1, "or_else(async): expected fallback to win")
            assert(tries() == 1, "async_task: try_fn should be called exactly once")
            assert(fallback_called == true,
                "or_else(async): fallback should run when event is not ready")
        end

        -- nested wrap: ((x + 1) * 2)
        local ev3 = always(5)
            :wrap(function(x) return x + 1 end)
            :wrap(function(y) return y * 2 end)
        local v3 = perform(ev3)
        assert(v3 == 12, "nested wrap: wrong result")
    end

    --------------------------------------------------------
    -- 2) Blocking path: async_task
    --------------------------------------------------------
    do
        local ev, tries = async_task(42)
        local v = perform(ev)
        assert(v == 42, "async_task: wrong result")
        assert(tries() == 1, "async_task: try_fn not called exactly once")
    end

    --------------------------------------------------------
    -- 3) Choice + wrap
    --------------------------------------------------------
    do
        -- choice over multiple ready events
        local choice_ev = choice(always(1), always(2), always(3))
        for _ = 1, 5 do
            local v = perform(choice_ev)
            assert(v == 1 or v == 2 or v == 3,
                "choice(ready): result not in {1,2,3}")
        end

        -- wrap on choice
        local ev = choice(always(1), always(2)):wrap(function(x)
            return x * 10
        end)
        local v = perform(ev)
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
            return always(42)
        end
        local ev = op.guard(g)
        local v = perform(ev)
        assert(v == 42, "guard basic: wrong result")
        assert(calls == 1, "guard basic: builder not called once")

        -- guard in choice (ensures builder runs each sync)
        local calls2 = 0
        local guarded = op.guard(function()
            calls2 = calls2 + 1
            return always(10)
        end)
        local choice_ev = choice(guarded, always(20))
        local runs = 5
        for _ = 1, runs do
            local r = perform(choice_ev)
            assert(r == 10 or r == 20,
                "guard in choice: result not in {10,20}")
        end
        assert(calls2 == runs, "guard in choice: builder call mismatch")

        -- guard + with_nack (builder returns a with_nack event)
        local guard_calls, cancelled = 0, false
        local guarded_nack = op.guard(function()
            guard_calls = guard_calls + 1
            return op.with_nack(function(nack_ev)
                runtime.spawn(function()
                    perform(nack_ev)
                    cancelled = true
                end)
                return never()
            end)
        end)

        local ev2 = choice(guarded_nack, always("OK"))
        local v2  = perform(ev2)
        assert(v2 == "OK", "guard+with_nack: wrong winner")

        runtime.yield()
        assert(cancelled == true, "guard+with_nack: nack not fired")
        assert(guard_calls == 1, "guard+with_nack: builder not once")
    end

    --------------------------------------------------------
    -- 5) or_else on composite events
    --------------------------------------------------------
    do
        -- composite ready: choice(always, always)
        local comp_ready = choice(always(1), always(2))
        local ev1 = comp_ready:or_else(function() return 99 end)
        local r1 = perform(ev1)
        assert(r1 == 1 or r1 == 2,
            "or_else(composite ready): wrong result")

        -- composite never-ready: choice(never, never) → fallback
        local comp_never = choice(never(), never())
        local ev2 = comp_never:or_else(function() return 42 end)
        local r2 = perform(ev2)
        assert(r2 == 42, "or_else(composite none): fallback not used")
    end

    --------------------------------------------------------
    -- 6) with_nack: winner vs loser, basic nesting
    --------------------------------------------------------
    do
        -- 6.1 with_nack branch wins: nack must NOT fire
        do
            local cancelled = false
            local with_nack_ev = op.with_nack(function(nack_ev)
                runtime.spawn(function()
                    perform(nack_ev)
                    cancelled = true
                end)
                return always("WIN")
            end)

            local ev = choice(with_nack_ev, never())
            local v  = perform(ev)
            assert(v == "WIN", "with_nack win: wrong winner")

            runtime.yield()
            assert(cancelled == false, "with_nack win: nack fired unexpectedly")
        end

        -- 6.2 with_nack branch loses: nack MUST fire
        do
            local cancelled = false
            local with_nack_ev = op.with_nack(function(nack_ev)
                runtime.spawn(function()
                    perform(nack_ev)
                    cancelled = true
                end)
                return never()
            end)

            local ev = choice(with_nack_ev, always("OTHER"))
            local v  = perform(ev)
            assert(v == "OTHER", "with_nack loss: wrong winner")

            runtime.yield()
            assert(cancelled == true, "with_nack loss: nack did not fire")
        end

        -- 6.3 basic nested with_nack:
        --     outer subtree wins via inner leaf → neither nack fires.
        do
            local outer_cancelled, inner_cancelled = false, false

            local outer = op.with_nack(function(outer_nack_ev)
                runtime.spawn(function()
                    perform(outer_nack_ev)
                    outer_cancelled = true
                end)

                return op.with_nack(function(inner_nack_ev)
                    runtime.spawn(function()
                        perform(inner_nack_ev)
                        inner_cancelled = true
                    end)
                    return always("INNER_WIN")
                end)
            end)

            local ev = choice(outer, never())
            local v  = perform(ev)
            assert(v == "INNER_WIN",
                   "nested with_nack: wrong result")

            runtime.yield()
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
                    return always(99)
                end
            )

            local v = perform(ev)
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
                    return never()
                end
            )

            local ev = choice(bracket_ev, always("WIN"))
            local v  = perform(ev)
            assert(v == "WIN", "bracket choice: wrong winner")

            assert(acq_count == 1, "bracket choice: acquire not once")
            assert(use_count == 1, "bracket choice: use not once")
            assert(rel_count == 1, "bracket choice: release not once")
            assert(last_aborted == true,
                "bracket choice: aborted flag should be true when losing")
        end

        ----------------------------------------------------
        -- 7.3 bracket + or_else:
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
                    return never()
                end
            )

            local ev = bracket_ev:or_else(function()
                fallback_called = true
                return "FALLBACK"
            end)

            local res = perform(ev)

            assert(res == "FALLBACK",
                "bracket+or_else: expected fallback result")
            assert(fallback_called == true,
                "bracket+or_else: fallback thunk not called")

            assert(acq_count == 1, "bracket+or_else: acquire once")
            assert(use_count == 1, "bracket+or_else: use once")
            assert(rel_count == 1, "bracket+or_else: release once")
            assert(last_aborted == true,
                "bracket+or_else: aborted flag should be true when losing")
        end
    end

    --------------------------------------------------------
    -- 8) finally: cleanup on success and on abort
    --
    -- In the new model:
    --   finally(cleanup) is about lifetime:
    --     * cleanup(false) on normal success
    --     * cleanup(true) if the event participates in a choice and loses
    --   It does not intercept Lua errors; those are handled by scopes.
    --------------------------------------------------------
    do
        -- 8.1 success path: cleanup(false) once, result propagated
        do
            local calls = {}
            local base  = always(7)

            local ev    = base:finally(function(aborted)
                calls[#calls + 1] = aborted
            end)

            local r     = perform(ev)
            assert(r == 7, "finally(success): wrong result")
            assert(#calls == 1, "finally(success): cleanup not called once")
            assert(calls[1] == false,
                "finally(success): aborted should be false")
        end

        -- 8.2 abort path: event loses in a choice → cleanup(true)
        do
            local calls = {}

            -- This event never commits, so in choice it always loses.
            local base = never():finally(function(aborted)
                calls[#calls + 1] = aborted
            end)

            local ev = choice(base, always("WIN"))
            local r  = perform(ev)

            assert(r == "WIN",
                "finally(abort): wrong winner")
            assert(#calls == 1,
                "finally(abort): cleanup not called once")
            assert(calls[1] == true,
                "finally(abort): aborted should be true")
        end
    end

    print("fibers.op tests: ok")
    runtime.stop()
end)

runtime.main()

--- Tests the Op implementation.
print('testing: fibers.op')

-- look one level up
package.path = "../?.lua;" .. package.path

local op     = require 'fibers.op'
local fiber = require 'fibers.fiber'

local function task(val)
    local wrap_fn = function(x) return x end
    local try_fn = function() return true, val end
    local block_fn = function() end
    return op.new_base_op(wrap_fn, try_fn, block_fn)
end

-- Test base op
fiber.spawn(function()
    local baseOp = task(1)
    assert(baseOp:perform() == 1, "Base operation failed")
    fiber.stop()
end)
fiber.main()

-- Test choice op
fiber.spawn(function()
    local choiceOp = op.choice(task(1), task(2), task(3))
    assert(choiceOp:perform() >= 1 and choiceOp:perform() <= 3, "Choice operation failed")
    fiber.stop()
end)
fiber.main()

-- Test perform_alt
fiber.spawn(function()
    local baseOp = task(1)
    assert(baseOp:perform_alt(function() return 2 end) == 1, "perform_alt operation failed")

    local choiceOp = op.choice(task(1), task(2), task(3))
    assert(choiceOp:perform_alt(function() return 4 end) >= 1 and choiceOp:perform_alt(function() return 4 end) <= 3,
        "Choice operation perform_alt failed")
    fiber.stop()
end)
fiber.main()

----------------------------------------------------------------
-- guard
----------------------------------------------------------------

-- 1) Basic guard: behaves like g():perform(), builder called once per sync
fiber.spawn(function()
    local calls = 0
    local g     = function()
        calls = calls + 1
        return task(42)
    end

    local ev    = op.guard(g)
    local v     = ev:perform()
    assert(v == 42, "guard basic: wrong result")
    assert(calls == 1, "guard basic: builder not called exactly once")

    fiber.stop()
end)
fiber.main()

-- 2) guard inside choice: participates fully, builder once per perform
fiber.spawn(function()
    local calls   = 0
    local g       = function()
        calls = calls + 1
        return task(10)
    end

    local guarded = op.guard(g)
    local choice  = op.choice(guarded, task(20))

    local runs    = 5
    for _ = 1, runs do
        local v = choice:perform()
        assert(v == 10 or v == 20,
            "guard in choice: result out of range")
    end

    -- g() should have been called once per synchronization
    assert(calls == runs, "guard in choice: builder call count mismatch")

    fiber.stop()
end)
fiber.main()

-- 3) guard + wrap: guard(g):wrap(f):perform() == f(g():perform())
fiber.spawn(function()
    local calls = 0
    local g = function()
        calls = calls + 1
        return task(5)
    end

    local ev = op.guard(g):wrap(function(x)
        return x * 2
    end)

    local v = ev:perform()
    assert(v == 10, "guard wrap: wrong result")
    assert(calls == 1, "guard wrap: builder not called exactly once")

    fiber.stop()
end)
fiber.main()

-- helper: an op that always fails its try() so perform_alt fallback is taken
local function never_op()
    local wrap_fn  = function(x) return x end
    local try_fn   = function() return false end
    local block_fn = function() end
    return op.new_base_op(wrap_fn, try_fn, block_fn)
end

-- 4) guard:perform_alt uses inner event and fallback correctly
fiber.spawn(function()
    local calls = 0
    local g = function()
        calls = calls + 1
        return never_op()
    end

    local ev = op.guard(g)
    local v = ev:perform_alt(function() return 99 end)

    assert(v == 99, "guard perform_alt: wrong fallback result")
    assert(calls == 1, "guard perform_alt: builder not called exactly once")

    fiber.stop()
end)
fiber.main()

-- 5) guard whose builder returns a ChoiceOp
fiber.spawn(function()
    local calls = 0
    local g = function()
        calls = calls + 1
        return op.choice(task(1), task(2))
    end

    local ev = op.guard(g)
    local v = ev:perform()

    assert(v == 1 or v == 2, "guard returning choice: result out of range")
    assert(calls == 1, "guard returning choice: builder not called exactly once")

    fiber.stop()
end)
fiber.main()

-- 6) Nested guards: guard(g1) where g1 returns guard(g2)
fiber.spawn(function()
    local outer_calls = 0
    local inner_calls = 0

    local inner_g = function()
        inner_calls = inner_calls + 1
        return task(7)
    end

    local outer_g = function()
        outer_calls = outer_calls + 1
        return op.guard(inner_g)
    end

    local ev = op.guard(outer_g):wrap(function(x)
        return x + 1
    end)

    local v = ev:perform()
    assert(v == 8, "nested guard: wrong result")
    assert(outer_calls == 1, "nested guard: outer builder call count mismatch")
    assert(inner_calls == 1, "nested guard: inner builder call count mismatch")

    fiber.stop()
end)
fiber.main()
print('test: ok')

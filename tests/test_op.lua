--- Tests the Op implementation.
print('testing: fibers.op')

-- look one level up
package.path = "../?.lua;" .. package.path

local op = require 'fibers.op'
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

print('test: ok')

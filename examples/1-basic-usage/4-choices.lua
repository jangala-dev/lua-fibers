--- Choice
-- The choice function lets a fiber wait on multiple operations.
-- Choice blocks until one of its suboperations can run, then it executes
-- that case. It chooses one at random if multiple are ready.
--
-- Example ported from Go's Select https://go.dev/tour/concurrency/5


package.path = "../../?.lua;../?.lua;" .. package.path

local fiber = require 'fibers.fiber'
local channel = require 'fibers.channel'
local op = require 'fibers.op'

local perform, choice = op.perform, op.choice

local function fibonacci(c, quit)
    local x, y = 0, 1
    local done = false
    repeat
        local task = choice(
            c:put_op(x):wrap(function()
                x, y = y, x+y
            end),
            quit:get_op():wrap(function()
                print("quit")
                done = true
            end)
        )
        perform(task)
    until done
end

fiber.spawn(function()
    local c = channel.new()
    local quit = channel.new()
    fiber.spawn(function()
        for _=1, 10 do
            print(c:get())
        end
        quit:put(0)
    end)
    fibonacci(c, quit)
    fiber.stop()
end)

fiber.main()

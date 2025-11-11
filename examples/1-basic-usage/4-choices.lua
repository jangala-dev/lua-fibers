--- Choice
-- The choice function lets a fiber wait on multiple operations.
-- Choice blocks until one of its suboperations can run, then it executes
-- that case. It chooses one at random if multiple are ready.
--
-- Example ported from Go's Select https://go.dev/tour/concurrency/5


package.path = "../../src/?.lua;../?.lua;" .. package.path

local fibers = require 'fibers'
local channel = require 'fibers.channel'

local perform, choice = fibers.perform, fibers.choice

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

local function main()
    local c = channel.new()
    local quit = channel.new()
    fibers.spawn(function()
        for _=1, 10 do
            print(c:get())
        end
        quit:put(0)
    end)
    fibonacci(c, quit)
end

fibers.run(main)

package.path = "../../?.lua;../?.lua;" .. package.path

local channel = require 'fibers.channel'
local fiber = require 'fibers.fiber'
local sleep = require 'fibers.sleep'

--- The go function uses a closure to returns a thunk
local function go(fn, args)
    return function ()
        fn(unpack(args))
    end
end

local function player(board, name)
    while true do
        local ball = board:get()
        ball = ball + 1
        print(name.." hits the ball, rally is now "..ball.." shots")
        sleep.sleep(.1)
        board:put(ball)
    end
end

local function main()
    local done = false
    fiber.spawn(function()
        local ball = 0
        local board = channel.new()
        fiber.spawn(go(player, {board, 'Alice'}))
        fiber.spawn(go(player, {board, 'Bijal'}))
        board:put(ball)
        sleep.sleep(2)
        -- this pattern, where the master fiber ending causes the scheduler to
        -- stop and so for the program to end is nice control flow
        fiber.current_scheduler.done = true
    end)
    fiber.current_scheduler:main()
end

main()
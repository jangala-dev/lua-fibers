package.path = "../../?.lua;../?.lua;" .. package.path

local channel = require 'fibers.channel'
local fiber = require 'fibers.fiber'
local sleep = require 'fibers.sleep'
local go = require 'fibers.go'

local function player(name, board)
    while true do
        local ball = board:get()
        ball = ball + 1
        print(name, ball)
        sleep.sleep(.1)
        board:put(ball)
    end
end

local function main()
    local ball = 0
    local board = channel.new()
    go(player, {'ping', board})
    go(player, {'pong', board})
    board:put(ball) -- game on; toss the ball
    sleep.sleep(1)
    board:get() -- game over; grab the ball
end

fiber.spawn(function()
    main()
    fiber.stop()
end)
fiber.main()
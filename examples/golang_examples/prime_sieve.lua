---
-- An implementation of the widely used Golang Prime Sieve using channels.
-- The original can be found at https://go.dev/play/p/9U22NfrXeq
-- Notes below

--look for packages one or two folder up.
package.path = "../../?.lua;../?.lua;" .. package.path

local channel = require 'fibers.channel'
local fiber = require 'fibers.fiber'
local go = require 'fibers.go'

local count = 100

-- Send the sequence 2, 3, 4, ... to channel 'tx'.
local function generate(tx)
    local n = 2
    while true do
        tx:put(n)
        n = n + 1
    end
end

-- Copy the values from channel 'rx' to channel 'tx',
-- removing those divisible by 'prime'.
local function filter(rx, tx, prime)
    while true do
        local i = rx:get()
        if i % prime ~= 0 then 
            tx:put(i) 
        end
    end
end

-- The prime sieve: Daisy-chain Filter processes.
local function main()
    local ch = channel.new()
    go(generate, {ch})
    for i=1,count do
        local prime = ch:get()
        print(prime)
        ch1 = channel.new()
        go(filter, {ch, ch1, prime})
        ch = ch1
    end
    fiber.current_scheduler.done = true
end

fiber.spawn(main)
fiber.current_scheduler:main()

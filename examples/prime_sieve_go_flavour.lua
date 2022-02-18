---
-- An implementation of the widely used Golang Prime Sieve using channels.
-- The original can be found at https://go.dev/play/p/9U22NfrXeq
-- Notes below

--look for packages one folder up.
package.path = "../?.lua;" .. package.path

local channel = require 'fibers.channel'
local fiber = require 'fibers.fiber'

local count = 100

-- The two functions below `generate` and `filter` have had to be modified to
-- return closures as `fiber.spawn` only accepts functions. Golang's `go`
-- keyword must actually prevent the function invocation that follows from being
-- immediately executed. Wonder if we can approximate with a helper function?

-- Send the sequence 2, 3, 4, ... to channel 'tx'.
local function generate(tx)
    return function ()
        local n = 2
        while true do
            tx:put(n)
            n = n + 1
        end
    end
end

-- Copy the values from channel 'rx' to channel 'tx',
-- removing those divisible by 'prime'.
local function filter(rx, tx, prime)
    return function ()
        while true do
            local i = rx:get()
            if i % prime ~= 0 then 
                tx:put(i) 
            end
        end
    end
end

-- The prime sieve: Daisy-chain Filter processes.
local function main()
    local done = false
    fiber.spawn(function()
        local ch = channel.new()
        fiber.spawn(generate(ch))
        for i=1,count do
            local prime = ch:get()
            print(prime)
            ch1 = channel.new()
            fiber.spawn(filter(ch, ch1, prime))
            ch = ch1
        end
        done = true
    end)
    while not done do fiber.current_scheduler:run() end
end

main()
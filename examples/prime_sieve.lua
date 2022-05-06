---
-- Classic Prime Sieve using channels.

--look for packages one folder up.
package.path = "../?.lua;" .. package.path

local channel = require 'fibers.channel'
local fiber = require 'fibers.fiber'

local function prime_sieve(count)
    local function sieve(p, rx)
        local tx = channel.new()
        fiber.spawn(function ()
            while true do
                local n = rx:get()
                if n % p ~= 0 then tx:put(n) end
            end
        end)
        return tx
    end
 
    local function integers_from(n)
        local tx = channel.new()
        fiber.spawn(function ()
            while true do
                tx:put(n)
                n = n + 1
            end
        end)
        return tx
    end
 
    local function primes()
        local tx = channel.new()
        fiber.spawn(function ()
            local rx = integers_from(2)
            while true do
                local p = rx:get()
                tx:put(p)
                rx = sieve(p, rx)
            end
        end)
        return tx
    end
 
    local done = false
    fiber.spawn(function()
        local rx = primes()
        for i=1,count do print(rx:get()) end
        done = true
    end)

    while not done do fiber.current_scheduler:run() end
end
 
prime_sieve(100)
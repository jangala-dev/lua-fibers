-- (c) Jangala

-- Use of this source code is governed by the XXXXXXXXX license; see COPYING.

-- Mutexes following the functionality of those in golang. Inspired by
--
--  https://towardsdev.com/golang-using-buffered-channel-like-a-mutex-9c7c80ec5c27

package.path = '../?.lua;' .. package.path

local fiber = require 'fibers.fiber'
local queue = require 'fibers.queue'
local go = require 'fibers.go'
local sleep = require 'fibers.sleep'

local function new()
    local ret = {}
    ret._q = queue.new(1)
    function ret:lock() self._q:put(true) end
    function ret:unlock() self._q:get() end
    return ret
end

local function selftest()
    local m = new()
    local x = 0

    local function incrementer()
        sleep.sleep(math.random()/10)
        m:lock()
        local temp = x
        sleep.sleep(math.random()/1000)
        x = temp + 1
        m:unlock()
    end

    for i=1,1000 do
        go(incrementer)
    end

    sleep.sleep(3)

    print(x)
end

fiber.spawn(selftest)
fiber.current_scheduler:main()

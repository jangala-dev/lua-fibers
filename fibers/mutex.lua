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
local waitgroup = require 'fibers.waitgroup'

local function new()
    local ret = {}
    ret._q = queue.new(1)
    function ret:lock() self._q:put(true) end
    function ret:unlock() self._q:get() end
    return ret
end

local function selftest()
    print('selftest: fibers.mutex')
    local function main()
        local m = new()
        local wg = waitgroup.new()
    
        local num_workers = 1000
        local x = 0
    
        local function worker()
            sleep.sleep(math.random()/100)
            m:lock()
            local temp = x
            sleep.sleep(math.random()/1000)
            x = temp + 1
            m:unlock()
        end
    
        for i=1,num_workers do
            wg.add()
            go(function()
                worker()
                wg.done()
            end)
        end

        wg.wait()
        
        assert(x==num_workers)
        print('selftest: ok')
    end

    go(function()
        main()
        fiber.current_scheduler:stop()
     end)
     fiber.current_scheduler:main()
end

return {
    new = new,
    selftest = selftest
}
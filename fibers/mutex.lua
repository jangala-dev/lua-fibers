-- (c) Jangala

-- Use of this source code is governed by the XXXXXXXXX license; see COPYING.

-- Mutexes following the functionality of those in golang. Inspired by
--
--  https://towardsdev.com/golang-using-buffered-channel-like-a-mutex-9c7c80ec5c27

package.path = '../?.lua;' .. package.path

local queue = require 'fibers.queue'
local op = require 'fibers.op'

local function new()
    local q = queue.new(1)
    local ret = {}
    function ret:lock_operation() return q:put_operation(1) end
    function ret:lock() self:lock_operation():perform() end
    -- need to add panic on unlock of unlocked mutex
    function ret:unlock_operation() return q:get_operation() end
    function ret:unlock() self:unlock_operation():perform() end
    function ret:trylock()
        return op.choice(self:lock_operation():wrap(function () return true end))
        :default(function() return false end)
        :perform()
    end
    return ret
end

local function selftest()
    local fiber = require 'fibers.fiber'
    local go = require 'fibers.go'
    local sleep = require 'fibers.sleep'
    local waitgroup = require 'fibers.waitgroup'

    print('selftest: fibers.mutex')
    local function main()
        local m = new()
        local wg = waitgroup.new()
        assert(m:trylock())
        assert(not m:trylock())
        assert(not m:trylock())
        m:unlock()
        
        local num_workers = 1000
        local x = 0
        
        local function worker()
            m:lock()
            local temp = x
            sleep.sleep(math.random()/1000)
            x = temp + 1
            m:unlock()
        end
        
        for i=1,num_workers do
            wg:add(1)
            go(function()
                sleep.sleep(math.random()/100)
                worker()
                wg:done()
            end)
        end
        
        wg:wait()
        
        print(x)
        
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
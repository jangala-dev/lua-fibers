package.path = "../../?.lua;../?.lua;" .. package.path


local go = require 'fibers.go'
local fiber = require 'fibers.fiber'
local sleep = require 'fibers.sleep'
local mutex = require 'fibers.mutex'
local waitgroup = require 'fibers.waitgroup'


print('selftest: fibers.mutex')
local function main()
    local m = mutex.new()
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
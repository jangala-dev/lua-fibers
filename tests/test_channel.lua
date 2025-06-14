print('testing: fibers.channel')

package.path = "../?.lua;" .. package.path

local fiber = require 'fibers.fiber'
local channel = require 'fibers.channel'

local function test_unbuffered()
    local chan = channel.new()
    fiber.spawn(function() chan:put(42) end)
    assert(chan:get() == 42, "basic transfer")

    local received, signal = true, channel.new()
    fiber.spawn(function()
        received = chan:get()
        signal:put(true)
    end)
    fiber.spawn(function()
        chan:put(nil)
        signal:put(true)
    end)
    signal:get()
    signal:get()
    assert(received == nil, "blocking transfer")
    print("Unbuffered passed")
end

local function test_buffered()
    local chan, signal = channel.new(2), channel.new()

    fiber.spawn(function()
        for i = 1, 4 do
            chan:put(i)
        end
        signal:put(true)
    end)
    fiber.spawn(function()
        for i = 1, 2 do
            assert(chan:get() == i)
        end
    end)

    signal:get()
    fiber.spawn(function()
        chan:put(5)
        signal:put(true)
    end)
    assert(chan:get() == 3)
    signal:get()
    assert(chan:get() == 4)
    assert(chan:get() == 5)
    print("Bounded buffered passed")
end

local function test_unbounded()
    local chan = channel.new(math.huge)
    for i = 1, 1000 do chan:put(i) end
    for i = 1, 1000 do assert(chan:get() == i) end

    local blocked = true
    fiber.spawn(function()
        chan:get()
        blocked = false
    end)
    assert(blocked, "get should block")
    print("Unbounded passed")
end

local function test_concurrent()
    local chan, signal, results = channel.new(1), channel.new(), {}
    fiber.spawn(function()
        for i = 1, 11 do chan:put(i) end
        signal:put()
    end)
    fiber.spawn(function()
        for _ = 1, 10 do table.insert(results, chan:get()) end
        signal:put()
    end)
    signal:get()
    signal:get()
    for i = 1, 10 do assert(results[i] == i) end
    print("Concurrent passed")
end

fiber.spawn(function()
    test_unbuffered()
    test_buffered()
    test_unbounded()
    test_concurrent()
    print("All channel tests passed!")
    fiber.stop()
end)

fiber.main()

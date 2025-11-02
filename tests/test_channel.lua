print('testing: fibers.channel (Scope/Op model, ambient scope)')

package.path = "../?.lua;" .. package.path

local fiber   = require 'fibers.fiber'
local scope   = require 'fibers.scope'
local channel = require 'fibers.channel'

-- small helpers to keep assertions tidy
local function ch_put_ok(ch, v)
    local ok, cause = ch:put(v) -- ambient scope
    assert(ok, "put failed: " .. tostring(cause))
end

local function ch_get_ok(ch)
    local ok, v_or_cause = ch:get() -- ambient scope
    assert(ok, "get failed: " .. tostring(v_or_cause))
    return v_or_cause
end

local function test_unbuffered()
    local chan = channel.new()
    fiber.spawn(function() ch_put_ok(chan, 42) end)
    assert(ch_get_ok(chan) == 42, "basic transfer")

    local received, signal = true, channel.new()
    fiber.spawn(function()
        local ok, v = chan:get()
        assert(ok, "get failed in receiver")
        received = v
        ch_put_ok(signal, true)
    end)
    fiber.spawn(function()
        ch_put_ok(chan, nil)
        ch_put_ok(signal, true)
    end)
    -- wait for both spawned fibers to signal
    assert(ch_get_ok(signal) == true)
    assert(ch_get_ok(signal) == true)
    assert(received == nil, "blocking transfer")
    print("Unbuffered passed")
end

local function test_buffered()
    local chan, signal = channel.new(2), channel.new()

    fiber.spawn(function()
        for i = 1, 4 do ch_put_ok(chan, i) end
        ch_put_ok(signal, true)
    end)

    fiber.spawn(function()
        for i = 1, 2 do
            assert(ch_get_ok(chan) == i)
        end
    end)

    assert(ch_get_ok(signal) == true)
    fiber.spawn(function()
        ch_put_ok(chan, 5)
        ch_put_ok(signal, true)
    end)
    assert(ch_get_ok(chan) == 3)
    assert(ch_get_ok(signal) == true)
    assert(ch_get_ok(chan) == 4)
    assert(ch_get_ok(chan) == 5)
    print("Bounded buffered passed")
end

local function test_unbounded()
    local chan = channel.new(math.huge)
    for i = 1, 1000 do ch_put_ok(chan, i) end
    for i = 1, 1000 do assert(ch_get_ok(chan) == i) end

    local blocked = true
    fiber.spawn(function()
        -- this will block until someone puts; we don't put, so 'blocked' stays true here
        chan:get()
        blocked = false
    end)
    assert(blocked, "get should block")
    print("Unbounded passed")
end

local function test_concurrent()
    local chan, signal, results = channel.new(1), channel.new(), {}

    fiber.spawn(function()
        for i = 1, 11 do ch_put_ok(chan, i) end
        ch_put_ok(signal) -- no value
    end)

    fiber.spawn(function()
        for _ = 1, 10 do table.insert(results, ch_get_ok(chan)) end
        ch_put_ok(signal)
    end)

    ch_get_ok(signal)
    ch_get_ok(signal)

    for i = 1, 10 do assert(results[i] == i) end
    print("Concurrent passed")
end

-- Run tests inside a root scope so all fibers inherit the ambient scope.
local s = scope.new(nil) -- no timeout; pure ambient carrier
s:spawn(function()
    test_unbuffered()
    test_buffered()
    test_unbounded()
    test_concurrent()
    print("All channel tests passed!")
    fiber.stop()
end)

fiber.main()

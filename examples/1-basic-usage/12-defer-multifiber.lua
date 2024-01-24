package.path = "../../?.lua;../?.lua;" .. package.path

local fiber = require 'fibers.fiber'
local channel = require 'fibers.channel'

local defscope = fiber.defscope
local defer, fpcall = fiber.defer, fiber.fpcall

local res_chan = channel.new()

local function first()
    local never_happens, happens = false, false
    local test1 = defscope(function()
        defer(function() happens = true end)
        defer(res_chan.put, res_chan, "A")
        defer(res_chan.put, res_chan, "B")
        error({"error_obj"})
        never_happens = true -- will never happen due to error above
    end)
    local res = fpcall(test1)
    assert(happens and not never_happens)
    res_chan:put(res[1])
    print("message from second:", res_chan:get())
    res_chan:put("acknowledged")
end

local function second()
    local test1 = defscope(function()
        defer(res_chan.put, res_chan, "terminating")
        print(res_chan:get()) -- 'B' (defers done in reverse order)
        print(res_chan:get()) -- 'A'
        print(res_chan:get()) -- error processes after all defers
    end)
    test1()
    print("message from first:", res_chan:get())
    fiber.stop()
end

fiber.spawn(function ()
    fiber.spawn(first)
    fiber.spawn(second)
end)

fiber.main()
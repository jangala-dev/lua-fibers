-- test_channel2.lua

local runtime  = require 'fibers.runtime'
local op2      = require 'fibers.op2'
local channel2 = require 'fibers.channel2'

runtime.spawn_raw(function ()
    local ch = channel2.new()

    local got, done = nil, false

    runtime.spawn_raw(function ()
        got = op2.perform(ch:get_op())
        done = true
    end)

    runtime.spawn_raw(function ()
        local ok = op2.perform(ch:put_op(42))
        assert(ok == true)
    end)

    while not done do
        runtime.yield()
    end
    assert(got == 42)

    runtime.stop()
end)

runtime.main()

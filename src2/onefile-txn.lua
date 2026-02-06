-- and_then_simple.lua
-- A simpler approach that actually works

local unpack = unpack or table.unpack

----------------------------------------------------------------------
-- Simple Scheduler with Pulse
----------------------------------------------------------------------

local Pulse = {}
Pulse.__index = Pulse

function Pulse.new()
    return setmetatable({
        waiters = {}
    }, Pulse)
end

function Pulse:wait(fiber)
    table.insert(self.waiters, fiber)
    return coroutine.yield()
end

function Pulse:signal()
    local waiters = self.waiters
    self.waiters = {}
    for _, fiber in ipairs(waiters) do
        fiber.scheduler:schedule(fiber)
    end
end

local Scheduler = {}
Scheduler.__index = Scheduler

function Scheduler.new()
    return setmetatable({
        ready = {},
        running = false,
        pulse = Pulse.new()
    }, Scheduler)
end

function Scheduler:schedule(fiber)
    if fiber._scheduled then return end
    fiber._scheduled = true
    table.insert(self.ready, fiber)

    if not self.running then
        self:run()
    end
end

function Scheduler:run()
    if self.running then return end
    self.running = true

    while #self.ready > 0 do
        local fiber = table.remove(self.ready, 1)
        fiber._scheduled = false

        local ok, pulse = coroutine.resume(fiber.co)

        if not ok then
            error(("Fiber crashed: %s"):format(tostring(pulse)))
        elseif pulse then
            -- Fiber yielded, will be woken by pulse:signal()
            pulse:wait(fiber)
        end
    end

    self.running = false
end

----------------------------------------------------------------------
-- Operation Protocol
----------------------------------------------------------------------

local Operation = {}
Operation.__index = Operation

function Operation.new()
    return setmetatable({}, Operation)
end

function Operation:prepare()
    error("abstract method")
end

function Operation:finish()
    error("abstract method")
end

function Operation:abort()
    -- default: do nothing
end

local function perform(op)
    while true do
        local ok, pulse = op:prepare()
        if ok then
            return op:finish()
        end
        pulse:wait({ scheduler = scheduler, co = coroutine.running() })
    end
end

----------------------------------------------------------------------
-- and_then implementation
----------------------------------------------------------------------

local AndThenOp = {}
AndThenOp.__index = AndThenOp

function and_then(first, k)
    -- k is a function that takes the result of first and returns a new op
    local op = setmetatable({
        first = first,
        k = k,
        state = "first", -- "first", "second", "done"
        result = nil
    }, AndThenOp)

    return op
end

function AndThenOp:prepare()
    if self.state == "done" then
        return true
    end

    if self.state == "first" then
        local ready, pulse = self.first:prepare()
        if not ready then
            return false, pulse
        end

        -- Store the preview from first op
        self.first_preview = self.first._preview
        self.state = "second"

        -- Generate second op using the preview
        self.second = self.k(self.first_preview)

        -- Try to prepare second op
        local second_ready, second_pulse = self.second:prepare()
        if not second_ready then
            self.state = "first"  -- Reset so we retry from first
            return false, second_pulse
        end

        return true
    end

    return false, scheduler.pulse
end

function AndThenOp:finish()
    if self.state == "done" then
        return self.result
    end

    -- Finish first op
    local first_result = self.first:finish()

    -- Finish second op
    local second_result = self.second:finish()

    self.state = "done"
    self.result = second_result
    return second_result
end

function AndThenOp:abort()
    if self.state == "second" then
        self.first:abort()
        self.second:abort()
        self.state = "first"
        self.second = nil
        self.first_preview = nil
    end
end

----------------------------------------------------------------------
-- Simple Channel (working version)
----------------------------------------------------------------------

local Channel = {}
Channel.__index = Channel

function Channel.new(name)
    return setmetatable({
        name = name,
        puts = {},
        gets = {},
        pulse = Pulse.new(),
        matches = 0
    }, Channel)
end

-- Put operation
function Channel:put_op(value)
    local op = Operation.new()
    op.value = value
    op.channel = self

    function op:prepare()
        if self.done then return true end

        local channel = self.channel

        -- Look for matching get
        for i, get_op in ipairs(channel.gets) do
            if not get_op.done and not get_op.matched then
                -- Match found!
                self.matched_with = get_op
                get_op.matched_with = self
                self._preview = true  -- Preview for put is just "ready"
                get_op._preview = self.value  -- Get gets the value as preview
                return true
            end
        end

        -- No match, wait
        table.insert(channel.puts, self)
        return false, channel.pulse
    end

    function op:finish()
        if self.done then return true end

        local channel = self.channel
        local get_op = self.matched_with

        if not get_op then
            error("Put operation finished without match")
        end

        -- Complete the transfer
        get_op.result = self.value
        get_op.done = true
        self.done = true

        -- Remove from waiting lists
        for i, v in ipairs(channel.puts) do
            if v == self then table.remove(channel.puts, i) break end
        end
        for i, v in ipairs(channel.gets) do
            if v == get_op then table.remove(channel.gets, i) break end
        end

        channel.matches = channel.matches + 1
        channel.pulse:signal()

        return true
    end

    function op:abort()
        if self.matched_with then
            self.matched_with.matched_with = nil
            self.matched_with = nil
        end

        local channel = self.channel
        for i, v in ipairs(channel.puts) do
            if v == self then
                table.remove(channel.puts, i)
                break
            end
        end
    end

    return op
end

-- Get operation
function Channel:get_op()
    local op = Operation.new()
    op.channel = self
    op.result = nil

    function op:prepare()
        if self.done then return true end

        local channel = self.channel

        -- Look for matching put
        for i, put_op in ipairs(channel.puts) do
            if not put_op.done and not put_op.matched then
                -- Match found!
                self.matched_with = put_op
                put_op.matched_with = self
                self._preview = put_op.value  -- Preview is the value we'll get
                put_op._preview = true
                return true
            end
        end

        -- No match, wait
        table.insert(channel.gets, self)
        return false, channel.pulse
    end

    function op:finish()
        if self.done then return self.result end

        local channel = self.channel
        local put_op = self.matched_with

        if not put_op then
            error("Get operation finished without match")
        end

        self.result = put_op.value
        self.done = true

        -- The put op will handle removal in its finish
        put_op:finish()

        return self.result
    end

    function op:abort()
        if self.matched_with then
            self.matched_with.matched_with = nil
            self.matched_with = nil
        end

        local channel = self.channel
        for i, v in ipairs(channel.gets) do
            if v == self then
                table.remove(channel.gets, i)
                break
            end
        end
    end

    return op
end

-- Convenience methods
function Channel:put(value)
    return perform(self:put_op(value))
end

function Channel:get()
    return perform(self:get_op())
end

----------------------------------------------------------------------
-- Demo
----------------------------------------------------------------------

-- Global scheduler for the demo
local scheduler = Scheduler.new()

-- Override perform to use our scheduler
local original_perform = perform
perform = function(op)
    while true do
        local ok, pulse = op:prepare()
        if ok then
            return op:finish()
        end
        pulse:wait({ scheduler = scheduler, co = coroutine.running() })
    end
end

local function run_demo()
    print("=== Simple Demo ===")

    local chan = Channel.new("test")

    -- Create fibers
    local prod = coroutine.create(function()
        print("[Producer] Putting 42")
        chan:put(42)
        print("[Producer] Done")
    end)

    local cons = coroutine.create(function()
        print("[Consumer] Getting...")
        local val = chan:get()
        print("[Consumer] Got: " .. tostring(val))
    end)

    scheduler:schedule({co = prod, _scheduled = false})
    scheduler:schedule({co = cons, _scheduled = false})

    scheduler:run()

    print("Matches: " .. chan.matches)
    print()

    print("=== and_then Demo ===")

    local chan1 = Channel.new("chan1")
    local chan2 = Channel.new("chan2")

    -- Setup producers in separate fibers
    scheduler:schedule({
        co = coroutine.create(function()
            print("[P1] Putting 'hello' into chan1")
            chan1:put("hello")
            print("[P1] Done")
        end),
        _scheduled = false
    })

    scheduler:schedule({
        co = coroutine.create(function()
            print("[P2] Putting 'world' into chan2")
            chan2:put("world")
            print("[P2] Done")
        end),
        _scheduled = false
    })

    -- Run producers first
    scheduler:run()

    -- Now do the and_then transaction
    local txn_fiber = coroutine.create(function()
        print("[Txn] Starting and_then sequence")

        -- Create the composite operation
        local op = and_then(chan1:get_op(), function(val1)
            print("[Txn] First preview: " .. tostring(val1))
            if val1 == "hello" then
                print("[Txn] Getting from chan2")
                return chan2:get_op()
            else
                print("[Txn] Unexpected value")
                -- Return a failing op
                local fail = Operation.new()
                function fail:prepare()
                    return false, Pulse.new()  -- Never ready
                end
                function fail:finish()
                    error("Should not reach here")
                end
                return fail
            end
        end)

        local result = perform(op)
        print("[Txn] Result: " .. tostring(result))

        -- Put combined result
        local combined = "hello " .. result .. "!"
        print("[Txn] Putting combined: " .. combined)
        chan1:put(combined)
    end)

    scheduler:schedule({co = txn_fiber, _scheduled = false})

    -- Final receiver
    local final_fiber = coroutine.create(function()
        print("[Final] Waiting for result...")
        local val = chan1:get()
        print("[Final] Got: " .. tostring(val))
    end)

    scheduler:schedule({co = final_fiber, _scheduled = false})

    scheduler:run()

    print("chan1 matches: " .. chan1.matches)
    print("chan2 matches: " .. chan2.matches)
    print()

    print("=== Performance Test ===")

    local chan3 = Channel.new("perf")
    local iterations = 1000000
    local start = os.clock()

    -- Producer
    local prod_fiber = coroutine.create(function()
        for i = 1, iterations do
            chan3:put(i)
        end
        print("[Perf] Producer done")
    end)

    -- Consumer
    local cons_fiber = coroutine.create(function()
        local total = 0
        for i = 1, iterations do
            total = total + chan3:get()
        end
        print("[Perf] Consumer done, total: " .. total)
        local expected = iterations * (iterations + 1) / 2
        print("[Perf] Expected: " .. expected .. ", Match: " .. (total == expected and "YES" or "NO"))
    end)

    scheduler:schedule({co = prod_fiber, _scheduled = false})
    scheduler:schedule({co = cons_fiber, _scheduled = false})

    scheduler:run()

    local elapsed = os.clock() - start
    print(string.format("Time: %.3f seconds", elapsed))
    if elapsed > 0 then
        print(string.format("Rate: %.0f ops/sec", (iterations * 2) / elapsed))
    end
    print("Matches: " .. chan3.matches)
end

-- Run the demo
if pcall(run_demo) then
    print("\n=== Demo completed ===")
else
    print("\n!!! Demo failed !!!")
    print(debug.traceback())
end

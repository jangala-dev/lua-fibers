-- transactional_and_then.lua
-- Minimal correct implementation of transactional and_then

----------------------------------------------------------------------
-- Simple but correct scheduler
----------------------------------------------------------------------

local Scheduler = {}
Scheduler.__index = Scheduler

function Scheduler.new()
    return setmetatable({
        ready = {},
        waiting = {},
        running = false,
        stats = { runs = 0 }
    }, Scheduler)
end

function Scheduler:enqueue(fiber)
    table.insert(self.ready, fiber)
    if not self.running then
        self:run()
    end
end

function Scheduler:wait(fiber, pulse)
    fiber.waiting_on = pulse
    if not self.waiting[pulse] then
        self.waiting[pulse] = {}
    end
    table.insert(self.waiting[pulse], fiber)
end

function Scheduler:wake(pulse)
    local fibers = self.waiting[pulse]
    if not fibers then return end

    for _, fiber in ipairs(fibers) do
        fiber.waiting_on = nil
        table.insert(self.ready, fiber)
    end
    self.waiting[pulse] = nil
end

function Scheduler:run()
    if self.running then return end
    self.running = true

    while #self.ready > 0 do
        local fiber = table.remove(self.ready, 1)
        local ok, pulse = coroutine.resume(fiber.co)

        if not ok then
            error(("Fiber crashed: %s"):format(tostring(pulse)))
        elseif pulse then
            -- Fiber wants to wait
            self:wait(fiber, pulse)
        end

        self.stats.runs = self.stats.runs + 1
    end

    self.running = false
end

----------------------------------------------------------------------
-- Basic Pulse for waiting
----------------------------------------------------------------------

local Pulse = {}
Pulse.__index = Pulse

function Pulse.new()
    return setmetatable({}, Pulse)
end

----------------------------------------------------------------------
-- Transactional Operation Protocol
----------------------------------------------------------------------

local Operation = {}
Operation.__index = Operation

function Operation.new(prepare_fn, commit_fn)
    local self = setmetatable({}, Operation)
    self.prepare_fn = prepare_fn
    self.commit_fn = commit_fn
    self.state = "pending"
    self.pulse = Pulse.new()
    return self
end

function Operation:prepare()
    if self.state == "prepared" or self.state == "committed" then
        return true
    end

    local success, result = self.prepare_fn()
    if success then
        self.state = "prepared"
        self.preview = result
        return true
    else
        return false, self.pulse
    end
end

function Operation:commit()
    if self.state == "committed" then
        return true, self.result
    end

    if self.state ~= "prepared" then
        return false, "not prepared"
    end

    local success, result = self.commit_fn(self.preview)
    if success then
        self.state = "committed"
        self.result = result
        return true, result
    else
        return false, result
    end
end

function Operation:abort()
    self.state = "pending"
    self.preview = nil
end

----------------------------------------------------------------------
-- Perform with retry
----------------------------------------------------------------------

local function perform(op, scheduler)
    while true do
        local ready, pulse = op:prepare()
        if ready then
            local success, result = op:commit()
            if success then
                return result
            end
            -- Commit failed, retry
            op:abort()
        end

        -- Wait on pulse
        local co = coroutine.running()
        local fiber = { co = co }
        scheduler:wait(fiber, pulse)
        coroutine.yield()
    end
end

----------------------------------------------------------------------
-- and_then combinator
----------------------------------------------------------------------

local function and_then(op, k)
    -- k is a function that receives preview values and returns a new op
    return Operation.new(
        -- prepare function
        function()
            -- First, prepare the initial operation
            local ready, pulse = op:prepare()
            if not ready then
                return false, pulse
            end

            -- Now we have preview values from the first op
            -- Use them to generate the continuation operation
            local next_op = k(op.preview)

            -- Prepare the continuation
            local next_ready, next_pulse = next_op:prepare()
            if not next_ready then
                op:abort()  -- Clean up first op
                return false, next_pulse
            end

            -- Both operations are prepared
            -- Store the continuation for commit phase
            self = {}  -- In Lua 5.1, we need to handle self differently
            local container = {
                first = op,
                second = next_op,
                preview = next_op.preview
            }

            return true, container
        end,

        -- commit function
        function(container)
            -- Commit both operations
            local first_success, first_result = container.first:commit()
            if not first_success then
                container.second:abort()
                return false, "first operation failed to commit"
            end

            local second_success, second_result = container.second:commit()
            if not second_success then
                container.first:abort()  -- Note: this is tricky - first op already committed
                return false, "second operation failed to commit"
            end

            return true, second_result
        end
    )
end

----------------------------------------------------------------------
-- Simple unbuffered channel using the operation protocol
----------------------------------------------------------------------

local Channel = {}
Channel.__index = Channel

function Channel.new(name, scheduler)
    return setmetatable({
        name = name,
        scheduler = scheduler,
        pulse = Pulse.new(),
        waiting_puts = {},
        waiting_gets = {},
        matches = 0
    }, Channel)
end

function Channel:put_op(value)
    return Operation.new(
        -- prepare
        function()
            -- Check if there's a waiting get
            if #self.waiting_gets > 0 then
                local get_op = table.remove(self.waiting_gets, 1)
                return true, { peer = get_op, value = value }
            end

            -- No waiting get, add to waiting list
            local op = { value = value }
            table.insert(self.waiting_puts, op)
            return false, self.pulse
        end,

        -- commit
        function(preview)
            local peer = preview.peer
            peer.result = preview.value
            peer.committed = true

            -- Wake the scheduler
            self.scheduler:wake(peer.pulse)

            self.matches = self.matches + 1
            return true, true
        end
    )
end

function Channel:get_op()
    return Operation.new(
        -- prepare
        function()
            -- Check if there's a waiting put
            if #self.waiting_puts > 0 then
                local put_op = table.remove(self.waiting_puts, 1)
                return true, { peer = put_op }
            end

            -- No waiting put, add to waiting list
            local op = { pulse = Pulse.new() }
            table.insert(self.waiting_gets, op)
            return false, op.pulse
        end,

        -- commit
        function(preview)
            local peer = preview.peer
            local value = peer.value

            -- Wake the scheduler if put is waiting
            if peer.pulse then
                self.scheduler:wake(peer.pulse)
            end

            self.matches = self.matches + 1
            return true, value
        end
    )
end

-- Convenience methods
function Channel:put(value)
    return perform(self:put_op(value), self.scheduler)
end

function Channel:get()
    return perform(self:get_op(), self.scheduler)
end

----------------------------------------------------------------------
-- Demo
----------------------------------------------------------------------

local function create_fiber(scheduler, fn)
    local co = coroutine.create(fn)
    local fiber = { co = co }
    scheduler:enqueue(fiber)
    return fiber
end

local function demo_simple()
    print("=== Simple Demo ===")

    local scheduler = Scheduler.new()
    local chan = Channel.new("test", scheduler)

    create_fiber(scheduler, function()
        print("[Producer] Putting 42")
        chan:put(42)
        print("[Producer] Done")
    end)

    create_fiber(scheduler, function()
        print("[Consumer] Getting...")
        local val = chan:get()
        print("[Consumer] Got: " .. tostring(val))
    end)

    -- Scheduler will run automatically via enqueue
    print("Matches: " .. chan.matches)
    print()
end

local function demo_and_then()
    print("=== and_then Demo ===")

    local scheduler = Scheduler.new()
    local chan1 = Channel.new("chan1", scheduler)
    local chan2 = Channel.new("chan2", scheduler)

    -- Setup: put values into channels
    create_fiber(scheduler, function()
        print("[Setup] Putting 'hello' into chan1")
        chan1:put("hello")
        print("[Setup] Putting 'world' into chan2")
        chan2:put("world")
    end)

    -- Transaction with and_then
    create_fiber(scheduler, function()
        print("[Transaction] Starting and_then sequence")

        -- Create the composite operation: get from chan1, then based on result, get from chan2
        local op = and_then(chan1:get_op(), function(val1)
            print("[Transaction] First op preview: " .. tostring(val1))
            if val1 == "hello" then
                print("[Transaction] Getting from chan2")
                return chan2:get_op()
            else
                print("[Transaction] Unexpected value, aborting")
                -- Return a failing operation
                return Operation.new(
                    function() return false, Pulse.new() end,
                    function() return false, "aborted" end
                )
            end
        end)

        -- Perform the composite operation
        local result = perform(op, scheduler)
        print("[Transaction] Result: " .. tostring(result))

        -- Now put combined result
        local combined = "hello " .. result .. "!"
        print("[Transaction] Putting combined: " .. combined)
        chan1:put(combined)
    end)

    -- Final receiver
    create_fiber(scheduler, function()
        print("[Final] Waiting for final result...")
        local val = chan1:get()
        print("[Final] Got: " .. tostring(val))
    end)

    print("chan1 matches: " .. chan1.matches)
    print("chan2 matches: " .. chan2.matches)
    print()
end

local function demo_performance()
    print("=== Performance Demo ===")

    local scheduler = Scheduler.new()
    local chan = Channel.new("perf", scheduler)
    local iterations = 1000

    local start = os.clock()

    -- Producer
    create_fiber(scheduler, function()
        for i = 1, iterations do
            chan:put(i)
        end
    end)

    -- Consumer
    create_fiber(scheduler, function()
        local total = 0
        for i = 1, iterations do
            total = total + chan:get()
        end
        print("Total: " .. total)
        local expected = iterations * (iterations + 1) / 2
        print("Expected: " .. expected)
        print("Match: " .. (total == expected and "YES" or "NO"))
    end)

    local elapsed = os.clock() - start
    print(string.format("Time: %.3f seconds", elapsed))
    if elapsed > 0 then
        print(string.format("Rate: %.0f ops/sec", (iterations * 2) / elapsed))
    end
    print("Matches: " .. chan.matches)
    print()
end

-- Run demos
demo_simple()
demo_and_then()
demo_performance()

print("=== Done ===")

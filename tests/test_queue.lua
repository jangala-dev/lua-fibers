--- Tests the Queue implementation.
print('testing: fibers.queue')

-- look one level up
package.path = "../src/?.lua;" .. package.path

local queue = require 'fibers.queue'
local runtime = require 'fibers.runtime'

local function equal(x, y)
    if type(x) ~= type(y) then return false end
    if type(x) == 'table' then
        for k, v in pairs(x) do
            if not equal(v, y[k]) then return false end
        end
        for k, _ in pairs(y) do
            if x[k] == nil then return false end
        end
        return true
    else
        return x == y
    end
end

local log = {}
local function record(x) table.insert(log, x) end

runtime.spawn_raw(function()
    local q = queue.new()
    record('a')
    q:put('b')
    record('c')
    q:put('d')
    record('e')
    record(q:get())
    q:put('f')
    record('g')
    record(q:get())
    record('h')
    record(q:get())
end)

local function run(...)
    log = {}
    runtime.current_scheduler:run()
    assert(equal(log, { ... }))
end

-- With the new buffered channel implementation, the behavior is  direct:
run('a', 'c', 'e', 'b', 'g', 'd', 'h', 'f')
for _ = 1, 20 do run() end

print('test: ok')

--- Tests the Sleep implementation.
print('testing: fibers.sleep')

-- look one level up
package.path = "../?.lua;" .. package.path

local sleep = require 'fibers.sleep'
local fiber = require 'fibers.fiber'

local done = 0
-- local wakeup_times = {}
local count = 1e3
for _ = 1, count do
    local function fn()
        local start, dt = fiber.now(), math.random()
        sleep.sleep(dt)
        local wakeup_time = fiber.now()
        assert(wakeup_time >= start + dt)
        done = done + 1
        -- table.insert(wakeup_times, wakeup_time - (start + dt))
    end
    fiber.spawn(fn)
end
for t = fiber.now(), fiber.now() + 1.5, 0.01 do
    fiber.current_scheduler:run(t)
end
assert(done == count)

-- -- Calculate maximum error
-- local max_error = 0
-- for _, error in ipairs(wakeup_times) do
--    if error > max_error then max_error = error end
-- end
-- print("Maximum sleep error: ", max_error)

print('test: ok')

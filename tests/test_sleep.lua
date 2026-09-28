--- Tests the Sleep implementation.
print('testing: fibers.sleep')

-- look one level up
package.path = '../src/?.lua;' .. package.path

local sleep = require 'fibers.sleep'
local runtime = require 'fibers.runtime'

local done = 0
-- local wakeup_times = {}
local count = 1e3
for _ = 1, count do
	local function fn()
		local start, dt = runtime.now(), math.random()
		sleep.sleep(dt)
		local wakeup_time = runtime.now()
		assert(wakeup_time >= start + dt)
		done = done + 1
		-- table.insert(wakeup_times, wakeup_time - (start + dt))
	end
	runtime.spawn_raw(fn)
end
for t = runtime.now(), runtime.now() + 1.5, 0.01 do
	runtime.current_scheduler:run(t)
end
assert(done == count)

print('test: ok')

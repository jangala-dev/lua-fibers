--- Regression test for losing sleep arms in choices.
---
--- A sleep operation that loses a choice must cancel and remove its scheduled
--- timer task immediately. Otherwise the timer heap retains the CompleteTask,
--- which retains the Suspension and its captured values until the deadline.
print('testing: fibers.sleep timer cancellation')

package.path = '../src/?.lua;' .. package.path

local fibers  = require 'fibers'
local op      = require 'fibers.op'
local sleep   = require 'fibers.sleep'
local runtime = require 'fibers.runtime'

local count = 2000

local function next_turn_op(value)
	return op.new_primitive(nil,
		function ()
			return false
		end,
		function (suspension, wrap_fn)
			suspension:wakeup(suspension:complete_task(wrap_fn, value))
		end
	)
end

local completed = 0

fibers.run(function ()
	local wheel = runtime.current_scheduler.wheel
	assert(wheel.heap.size == 0, 'timer heap unexpectedly non-empty at start')

	for i = 1, count do
		local value = fibers.perform(fibers.choice(
			next_turn_op(i),
			sleep.sleep_op(1e6)
		))

		assert(value == i)
		completed = completed + 1

		assert(wheel.heap.size == 0,
			('losing sleep_op left %d timer entries after iteration %d')
			:format(wheel.heap.size, i))

		if i % 250 == 0 then
			collectgarbage('collect')
			assert(wheel.heap.size == 0,
				('timer heap retained entries after GC at iteration %d'):format(i))
		end
	end
end)

assert(completed == count)

print('test: ok')

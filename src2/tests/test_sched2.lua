-- tests/test_sched2.lua
package.path = '../?.lua;' .. package.path

local sched = require 'fibers.sched2'

local function assert_eq(a, b, msg)
	if a ~= b then error((msg or 'assert_eq failed') .. (': got ' .. tostring(a) .. ', want ' .. tostring(b)), 2) end
end

local s = sched.new()
local ran = {}

local function task(name)
	return {
		_queued = false,
		run = function(self, _sched)
			ran[#ran + 1] = name
		end
	}
end

-- FIFO order; idempotent scheduling; step runs one task.
local a = task('A')
local b = task('B')

s:schedule(a)
s:schedule(a) -- idempotent
s:schedule(b)

assert_eq(s:step(), true, 'expected one task to run')
assert_eq(#ran, 1); assert_eq(ran[1], 'A')
assert_eq(a._queued, false, 'task should be unqueued after run')

assert_eq(s:step(), true, 'expected second task to run')
assert_eq(#ran, 2); assert_eq(ran[2], 'B')
assert_eq(b._queued, false)

assert_eq(s:step(), false, 'queue should now be empty')

-- Queue should be in a clean empty state.
assert_eq(s.head, 1, 'head should reset when empty')
assert_eq(s.tail, 0, 'tail should reset when empty')

io.write('ok: sched2\n')

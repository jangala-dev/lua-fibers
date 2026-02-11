-- tests/test_runtime.lua
package.path = '../?.lua;' .. package.path

local sched_mod = require 'fibers.sched'
local new_sched = sched_mod.new or (sched_mod.Scheduler and sched_mod.Scheduler.new)
assert(type(new_sched) == 'function', 'fibers.sched: no constructor found')

local runtime = require 'fibers.runtime'

local sched = new_sched()
runtime.init(sched)

local waker
local resumed = false

runtime.spawn(function()
  local ctx = runtime.ctx()
  waker = ctx.waker
  coroutine.yield(waker)
  resumed = true
end, 'waiter')

runtime.spawn(function()
  assert(waker ~= nil, 'expected waiter fibre to run first and publish its waker')
  waker:signal()
end, 'signaller')

runtime.main()
assert(resumed == true)

-- yielding a non-pulse should raise
local sched2 = new_sched()
runtime.init(sched2)

runtime.spawn(function()
  coroutine.yield(123)
end, 'bad-yield')

local ok, err = pcall(runtime.main)
assert(ok == false, 'expected runtime.main to error on invalid yield')
assert(tostring(err):match('invalid object') ~= nil, 'unexpected error: ' .. tostring(err))

print('test_runtime.lua: ok')

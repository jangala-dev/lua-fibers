package.path = '../?.lua;' .. package.path

local sched_mod = require 'fibers.sched'
local new_sched = sched_mod.new or (sched_mod.Scheduler and sched_mod.Scheduler.new)
assert(type(new_sched) == 'function', 'fibers.sched: no constructor found')

local pulse_mod = require 'fibers.pulse'
local new_pulse = pulse_mod.new or (pulse_mod.Pulse and pulse_mod.Pulse.new)
assert(type(new_pulse) == 'function', 'fibers.pulse: no constructor found')

local sched = new_sched()

local p = new_pulse(sched)

local ran = 0
local fib = {
  _queued = false,
  _waiting_pulse = nil,
  run = function()
    ran = ran + 1
  end,
}

p:subscribe(fib)
p:signal()

assert(sched:step() == true)
assert(ran == 1)

-- pending latch: signal before subscribe
local p2 = new_pulse(sched)
local ran2 = 0
local fib2 = {
  _queued = false,
  _waiting_pulse = nil,
  run = function()
    ran2 = ran2 + 1
  end,
}

p2:signal()
p2:subscribe(fib2)

assert(sched:step() == true)
assert(ran2 == 1)

-- cannot subscribe one fibre to two pulses
local p3 = new_pulse(sched)
local p4 = new_pulse(sched)
local fib3 = { _queued = false, _waiting_pulse = nil, run = function() end }

p3:subscribe(fib3)
local ok = pcall(function() p4:subscribe(fib3) end)
assert(ok == false, 'expected error when subscribing to two pulses')

print('test_pulse.lua: ok')

package.path = '../?.lua;' .. package.path

local sched_mod = require 'fibers.sched'
local new_sched = sched_mod.new or (sched_mod.Scheduler and sched_mod.Scheduler.new)
assert(type(new_sched) == 'function', 'fibers.sched: no constructor found')

local sched = new_sched()

local seen = {}
local function mk_task(id)
  return {
    _queued = false,
    run = function()
      seen[#seen + 1] = id
    end,
  }
end

local t1 = mk_task(1)
local t2 = mk_task(2)

-- idempotent enqueue
sched:schedule(t1)
sched:schedule(t1)
sched:schedule(t2)

assert(sched:step() == true)
assert(sched:step() == true)
assert(sched:step() == false)

assert(#seen == 2)
assert(seen[1] == 1 and seen[2] == 2, 'FIFO or idempotence failed')

-- queue should be reset to empty after draining
assert(sched:step() == false)

print('test_sched.lua: ok')

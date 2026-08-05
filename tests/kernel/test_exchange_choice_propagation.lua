package.path = table.concat({
  './src/?.lua', './src/?/init.lua', './src/?/?.lua',
  './?.lua', './?/init.lua', './?/?.lua', package.path,
}, ';')

local Runtime = require('fibers.runtime')
local Rendezvous = require('fibers.resource.rendezvous')
local Op = require('fibers.op')

local function eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'values differ') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual), 2)
  end
end

local function truthy(value, message)
  if not value then error(message or 'expected truthy value', 2) end
end

local function dispatch(wrapper, label, count)
  local rt = Runtime.new({ choice_seed = 2, instrumentation = true })
  local channels, received = {}, {}
  for worker = 1, count do
    channels[worker] = Rendezvous.new():label(label .. '-worker-' .. worker)
    local id = worker
    rt:spawn_raw(function() received[id] = rt:perform(channels[id]:get_op()) end):label(label .. '-worker-' .. id)
  end
  rt:spawn_raw(function()
    local jobs = {}
    for job = 1, count do
      local alternatives = {}
      for worker = 1, count do
        alternatives[worker] = wrapper(channels[worker]:put_op(job))
      end
      jobs[job] = Op.choice(alternatives)
    end
    rt:perform(Op.each(jobs))
  end):label(label .. '-dispatcher')
  eq(rt:run().tag, 'found')
  eq(rt:run().tag, 'idle')
  local seen = {}
  for worker = 1, count do
    local job = received[worker]
    truthy(type(job) == 'number' and job >= 1 and job <= count, 'worker did not receive a job')
    truthy(not seen[job], 'job was assigned more than once')
    seen[job] = true
  end
end

dispatch(function(op) return op end, 'plain-choice-propagation', 6)
dispatch(function(op) return op:map(function(value) return value end) end, 'mapped-choice-propagation', 5)
dispatch(function(op) return op:wrap(function(value) return value end) end, 'wrapped-choice-propagation', 5)

-- Guarded suppliers remain complete: a choice considered as a supplier may
-- still need its non-supplying alternative elsewhere in the same product.
do
  local rt = Runtime.new({ choice_seed = 1 })
  local a = Rendezvous.new():label('guard-supplier-completeness-a')
  local b = Rendezvous.new():label('guard-supplier-completeness-b')
  local got_a, got_b
  rt:spawn_raw(function() got_a = rt:perform(a:get_op()) end):label('get-a')
  rt:spawn_raw(function() got_b = rt:perform(b:get_op()) end):label('get-b')
  rt:spawn_raw(function()
    rt:perform(Op.each({
      Op.choice(
        Op.guard(function() return a:put_op('a-from-first') end),
        Op.guard(function() return b:put_op('b-from-first') end)
      ),
      Op.choice(
        Op.guard(function() return a:put_op('a-from-second') end),
        Op.never()
      ),
    }))
  end):label('guard-supplier-completeness-dispatcher')
  eq(rt:run().tag, 'found')
  eq(rt:run().tag, 'idle')
  eq(got_a, 'a-from-second')
  eq(got_b, 'b-from-first')
end

print('tests/kernel/test_exchange_choice_propagation.lua: ok')

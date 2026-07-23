package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './reference/?.lua',
  './reference/?/init.lua',
  './reference/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

local Runtime = require('fibers.runtime')
local Rendezvous = require('fibers.resource.rendezvous')
local Op = require('fibers.op')

local function eq(actual, expected, message)
  if actual ~= expected then
    error(
      (message or 'values differ') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual),
      2
    )
  end
end

local function truthy(value, message)
  if not value then
    error(message or 'expected truthy value', 2)
  end
end

-- A batch dispatcher is a normal application shape which can otherwise expand
-- into a factorial search: N independent job choices must select N distinct
-- waiting workers in one atomic product.
local n = 6
local rt =
  Runtime.new({ machine = os.getenv('FIBERS_MACHINE') or 'ledger', choice_seed = 1, instrumentation = true })
local workers, received = {}, {}
for worker = 1, n do
  workers[worker] = Rendezvous.new('choice-propagation-worker-' .. tostring(worker))
  local worker_id = worker
  rt:spawn_raw(function()
    received[worker_id] = rt:perform(workers[worker_id]:get_op())
  end, 'choice-propagation-worker-' .. tostring(worker))
end

rt:spawn_raw(function()
  local jobs = {}
  for job = 1, n do
    local alternatives = {}
    for worker = 1, n do
      alternatives[worker] = workers[worker]:put_op(job)
    end
    jobs[job] = Op.choice(alternatives)
  end
  rt:perform(Op.all(jobs))
end, 'choice-propagation-dispatcher')

eq(rt:run().tag, 'found')
eq(rt:run().tag, 'idle')
local seen = {}
for worker = 1, n do
  local job = received[worker]
  truthy(type(job) == 'number' and job >= 1 and job <= n, 'worker did not receive a job')
  truthy(not seen[job], 'job was assigned more than once')
  seen[job] = true
end

if rt.machine_name == 'ledger' then
  local counters = rt:instrumentation_snapshot().counters
  truthy((counters.search_calls or math.huge) < 100, 'exchange-choice propagation regressed')
  truthy((counters.choice_alternatives_pruned or 0) > 0, 'stale exchange alternatives were not pruned')
end

-- Outcome-only wrappers do not conceal the exchange shape from propagation.
-- Application code commonly labels or transforms the result of a send.
local function wrapped_dispatch(wrapper, label)
  local runtime = Runtime.new({
    machine = os.getenv('FIBERS_MACHINE') or 'ledger',
    choice_seed = 2,
    instrumentation = true,
  })
  local count = runtime.machine_name == 'ledger' and 8 or 4
  local channels, values = {}, {}
  for worker = 1, count do
    channels[worker] = Rendezvous.new(label .. '-worker-' .. tostring(worker))
    local worker_id = worker
    runtime:spawn_raw(function()
      values[worker_id] = runtime:perform(channels[worker_id]:get_op())
    end, label .. '-worker-' .. tostring(worker))
  end
  runtime:spawn_raw(function()
    local jobs = {}
    for job = 1, count do
      local alternatives = {}
      for worker = 1, count do
        alternatives[worker] = wrapper(channels[worker]:put_op(job))
      end
      jobs[job] = Op.choice(alternatives)
    end
    runtime:perform(Op.all(jobs))
  end, label .. '-dispatcher')
  eq(runtime:run().tag, 'found')
  eq(runtime:run().tag, 'idle')
  if runtime.machine_name == 'ledger' then
    local counters = runtime:instrumentation_snapshot().counters
    truthy((counters.search_calls or math.huge) < 100, label .. ' exchange propagation regressed')
    truthy((counters.choice_alternatives_pruned or 0) > 0, label .. ' alternatives were not pruned')
  end
end

wrapped_dispatch(function(op)
  return op:map(function(value)
    return value
  end)
end, 'mapped-choice-propagation')

wrapped_dispatch(function(op)
  return op:wrap(function(value)
    return value
  end)
end, 'annotated-choice-propagation')

print('tests/kernel/test_exchange_choice_propagation.lua: ok')

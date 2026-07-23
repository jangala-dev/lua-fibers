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

-- Opaque guard leaves should be revealed as supplier candidates rather than
-- accumulated into a Cartesian product of unresolved demands. The reference
-- evaluator remains the semantic oracle; the production threshold guards the
-- application-shaped cliff which motivated this propagation rule.
if (os.getenv('FIBERS_MACHINE') or 'ledger') == 'ledger' then
  for _, seed in ipairs({ 1, 2, 3 }) do
    local count = 7
    local runtime = Runtime.new({
      machine = 'ledger',
      choice_seed = seed,
      instrumentation = true,
    })
    local channels, values, guard_calls = {}, {}, 0
    for worker = 1, count do
      channels[worker] = Rendezvous.new('guarded-choice-worker-' .. tostring(seed) .. '-' .. tostring(worker))
      local worker_id = worker
      runtime:spawn_raw(function()
        values[worker_id] = runtime:perform(channels[worker_id]:get_op())
      end, 'guarded-choice-worker-' .. tostring(worker))
    end
    runtime:spawn_raw(function()
      local jobs = {}
      for job = 1, count do
        local job_id = job
        local alternatives = {}
        for worker = 1, count do
          local worker_id = worker
          alternatives[worker] = Op.guard(function()
            guard_calls = guard_calls + 1
            return channels[worker_id]:put_op(job_id)
          end)
        end
        jobs[job] = Op.choice(alternatives)
      end
      runtime:perform(Op.all(jobs))
    end, 'guarded-choice-dispatcher')

    eq(runtime:run().tag, 'found')
    eq(runtime:run().tag, 'idle')
    local assigned = {}
    for worker = 1, count do
      local job = values[worker]
      truthy(type(job) == 'number' and not assigned[job], 'guarded dispatch produced a duplicate job')
      assigned[job] = true
    end
    local counters = runtime:instrumentation_snapshot().counters
    truthy(
      (counters.search_calls or math.huge) < 100,
      'guard supplier propagation regressed at seed ' .. seed
    )
    truthy(guard_calls <= count * count, 'guard activation memoisation regressed')
  end
end

-- Outcome-only wrappers around a guard preserve the revealed rendezvous shape.
-- They should not reintroduce the opaque-guard cliff.
if (os.getenv('FIBERS_MACHINE') or 'ledger') == 'ledger' then
  local wrappers = {
    mapped_guard = function(op)
      return op:map(function(value)
        return value
      end)
    end,
    wrapped_guard = function(op)
      return op:wrap(function(value)
        return value
      end)
    end,
  }
  for label, wrapper in pairs(wrappers) do
    local count = 6
    local runtime = Runtime.new({ machine = 'ledger', choice_seed = 1, instrumentation = true })
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
        local job_id = job
        local alternatives = {}
        for worker = 1, count do
          local worker_id = worker
          alternatives[worker] = wrapper(Op.guard(function()
            return channels[worker_id]:put_op(job_id)
          end))
        end
        jobs[job] = Op.choice(alternatives)
      end
      runtime:perform(Op.all(jobs))
    end, label .. '-dispatcher')
    eq(runtime:run().tag, 'found')
    eq(runtime:run().tag, 'idle')
    local counters = runtime:instrumentation_snapshot().counters
    truthy((counters.search_calls or math.huge) < 100, label .. ' residual propagation regressed')
    truthy((counters.opaque_supplier_revelations or 0) > 0, label .. ' opaque suppliers were not revealed')
    truthy((counters.supplier_domain_branches or 0) > 0, label .. ' supplier domain was not used')
  end
end

-- A choice considered as a supplier must remain unresolved when another choice
-- ultimately supplies the demand. This preserves completeness: its
-- non-supplying alternative may still be required elsewhere in the product.
do
  local machine = os.getenv('FIBERS_MACHINE') or 'ledger'
  local runtime = Runtime.new({ machine = machine, choice_seed = 1 })
  local a = Rendezvous.new('guard-supplier-completeness-a')
  local b = Rendezvous.new('guard-supplier-completeness-b')
  local got_a, got_b

  runtime:spawn_raw(function()
    got_a = runtime:perform(a:get_op())
  end, 'guard-supplier-completeness-get-a')
  runtime:spawn_raw(function()
    got_b = runtime:perform(b:get_op())
  end, 'guard-supplier-completeness-get-b')
  runtime:spawn_raw(function()
    runtime:perform(Op.all({
      Op.choice(
        Op.guard(function()
          return a:put_op('a-from-first')
        end),
        Op.guard(function()
          return b:put_op('b-from-first')
        end)
      ),
      Op.choice(
        Op.guard(function()
          return a:put_op('a-from-second')
        end),
        Op.never()
      ),
    }))
  end, 'guard-supplier-completeness-dispatcher')

  eq(runtime:run().tag, 'found')
  eq(runtime:run().tag, 'idle')
  eq(got_a, 'a-from-second', machine .. ': wrong supplier committed for a')
  eq(got_b, 'b-from-first', machine .. ': non-supplying choice alternative was lost')
end

print('tests/kernel/test_exchange_choice_propagation.lua: ok')

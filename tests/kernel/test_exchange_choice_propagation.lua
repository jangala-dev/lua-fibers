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
local Domain = require('fibers.internal.kernel.domain')

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
local rt = Runtime.new({ choice_seed = 1, instrumentation = true })
local machine = rt.machine_name
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
  rt:perform(Op.each(jobs))
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
  local counters = rt:instrumentation_report().counters
  truthy((counters.search_calls or math.huge) < 100, 'exchange-choice propagation regressed')
  truthy((counters.choice_alternatives_pruned or 0) > 0, 'stale exchange alternatives were not pruned')
end

-- Exact matching failure is accepted only with a centrally checkable Hall
-- witness. A provider result which omits a possible supplier is rejected.
do
  local left = Rendezvous.new('matching-witness-left')
  local right = Rendezvous.new('matching-witness-right')
  local choices = {}
  for i = 1, 3 do
    choices[i] = Op.choice(left:put_op(i), right:put_op(i))
  end
  local requests = {
    [1] = { id = 1, op = Op.each(choices) },
    [2] = { id = 2, op = left:get_op() },
    [3] = { id = 3, op = right:get_op() },
  }
  local component = { ids = { 1, 2, 3 } }
  local witness = Domain.exact_exchange_matching_failure(requests, component)
  truthy(witness, 'exact matching provider did not produce a Hall witness')
  truthy(
    Domain.verify_exact_exchange_matching_failure(requests, component, witness),
    'valid Hall witness was rejected'
  )
  local generic = assert(Domain.exact_negative_failure(requests, component))
  eq(generic.kind, witness.kind, 'generic provider selected a different exact proof')
  truthy(
    Domain.verify_exact_negative_failure(requests, component, generic),
    'generic exact negative witness was rejected'
  )

  local omitted = {
    kind = witness.kind,
    domain_indices = witness.domain_indices,
    supplier_indices = {},
  }
  eq(
    Domain.verify_exact_exchange_matching_failure(requests, component, omitted),
    false,
    'incomplete supplier closure was accepted'
  )
end

-- An exact unsatisfiable assignment is a finite global constraint. The
-- production kernel proves the Hall deficit from the complete visible exchange
-- graph rather than enumerating every partial matching. The reference machine
-- remains exhaustive and is tested by the general semantic matrix.
if machine == 'ledger' then
  local jobs, worker_count = 7, 6
  local runtime = Runtime.new({ machine = 'ledger', instrumentation = true })
  local channels = {}
  for worker = 1, worker_count do
    channels[worker] = Rendezvous.new('matching-failure-worker-' .. tostring(worker))
    local worker_id = worker
    runtime:spawn_raw(function()
      runtime:perform(channels[worker_id]:get_op())
    end, 'matching-failure-worker-' .. tostring(worker))
  end
  runtime:spawn_raw(function()
    local lanes = {}
    for job = 1, jobs do
      local alternatives = {}
      for worker = 1, worker_count do
        alternatives[worker] = channels[worker]:put_op(job)
      end
      lanes[job] = Op.choice(alternatives)
    end
    runtime:perform(Op.each(lanes))
  end, 'matching-failure-dispatcher')
  eq(runtime:run().tag, 'quiescent')
  local counters = runtime:instrumentation_report().counters
  truthy((counters.matching_feasibility_failures or 0) > 0, 'matching failure was not proved')
  truthy((counters.search_calls or math.huge) <= 2, 'matching feasibility regressed to enumeration')
end

-- A finite matching fragment may become exact only after its guard leaves are
-- prepared. The provider reveals those guards under their normal activation
-- identities and still relies on the centrally verified Hall witness.
if machine == 'ledger' then
  local jobs, worker_count = 7, 6
  local runtime = Runtime.new({ machine = 'ledger', instrumentation = true })
  local channels = {}
  for worker = 1, worker_count do
    channels[worker] = Rendezvous.new('guarded-matching-failure-worker-' .. tostring(worker))
    local worker_id = worker
    runtime:spawn_raw(function()
      runtime:perform(channels[worker_id]:get_op())
    end, 'guarded-matching-failure-worker-' .. tostring(worker))
  end
  runtime:spawn_raw(function()
    local lanes = {}
    for job = 1, jobs do
      local alternatives = {}
      for worker = 1, worker_count do
        local job_id, worker_id = job, worker
        alternatives[worker] = Op.guard(function()
          return channels[worker_id]:put_op(job_id)
        end)
      end
      lanes[job] = Op.choice(alternatives)
    end
    runtime:perform(Op.each(lanes))
  end, 'guarded-matching-failure-dispatcher')
  eq(runtime:run().tag, 'quiescent')
  local counters = runtime:instrumentation_report().counters
  truthy((counters.matching_feasibility_failures or 0) > 0, 'guarded Hall failure was not proved')
  truthy(
    (counters.matching_guard_revelations or 0) >= jobs * worker_count,
    'matching guards were not exactified'
  )
  truthy((counters.search_calls or math.huge) <= 2, 'guarded matching failure regressed to enumeration')
end

-- Outcome-only wrappers do not conceal the exchange shape from propagation.
-- Application code commonly labels or transforms the result of a send.
local function wrapped_dispatch(wrapper, label)
  local runtime = Runtime.new({ choice_seed = 2, instrumentation = true })
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
    runtime:perform(Op.each(jobs))
  end, label .. '-dispatcher')
  eq(runtime:run().tag, 'found')
  eq(runtime:run().tag, 'idle')
  if runtime.machine_name == 'ledger' then
    local counters = runtime:instrumentation_report().counters
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
if machine == 'ledger' then
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
      runtime:perform(Op.each(jobs))
    end, 'guarded-choice-dispatcher')

    eq(runtime:run().tag, 'found')
    eq(runtime:run().tag, 'idle')
    local assigned = {}
    for worker = 1, count do
      local job = values[worker]
      truthy(type(job) == 'number' and not assigned[job], 'guarded dispatch produced a duplicate job')
      assigned[job] = true
    end
    local counters = runtime:instrumentation_report().counters
    truthy(
      (counters.search_calls or math.huge) < 100,
      'guard supplier propagation regressed at seed ' .. seed
    )
    truthy(guard_calls <= count * count, 'guard activation memoisation regressed')
  end
end

-- Outcome-only wrappers around a guard preserve the revealed rendezvous shape.
-- They should not reintroduce the opaque-guard cliff.
if machine == 'ledger' then
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
      runtime:perform(Op.each(jobs))
    end, label .. '-dispatcher')
    eq(runtime:run().tag, 'found')
    eq(runtime:run().tag, 'idle')
    local counters = runtime:instrumentation_report().counters
    truthy((counters.search_calls or math.huge) < 100, label .. ' residual propagation regressed')
    local matching_revelations = counters.matching_guard_revelations or 0
    truthy(
      (counters.opaque_supplier_revelations or 0) + matching_revelations > 0,
      label .. ' opaque suppliers were not revealed'
    )
    truthy(
      (counters.supplier_domain_branches or 0) > 0 or matching_revelations > 0,
      label .. ' supplier domain or exact matching pass was not used'
    )
  end
end

-- A provisional exchange pairing may be rejected only after its value enters an
-- and_then continuation.  The production search remembers that exact
-- activation pair for the current session rather than rediscovering the same
-- incompatibility through later permutations.
if machine == 'ledger' then
  local count = 7
  local runtime = Runtime.new({ machine = 'ledger', choice_seed = 1, instrumentation = true })
  local rendezvous = Rendezvous.new('value-routing-learning')
  local result
  runtime:spawn_raw(function()
    local lanes = {}
    for value = 1, count do
      lanes[#lanes + 1] = rendezvous:put_op(value)
    end
    for slot = 1, count do
      local expected = count - slot + 1
      lanes[#lanes + 1] = rendezvous:get_op():and_then(function(value)
        if value == expected then
          return Op.always(value)
        end
        return Op.never()
      end)
    end
    result = runtime:perform(Op.together(lanes))
  end, 'value-routing-learning')

  eq(runtime:run().tag, 'found')
  eq(runtime:run().tag, 'idle')
  truthy(result ~= nil, 'value-routing transaction did not complete')
  local counters = runtime:instrumentation_report().counters
  truthy(
    (counters.exchange_support_eliminations_learned or 0) > 0,
    'value-dependent exchange incompatibilities were not learned'
  )
  truthy(
    (counters.exchange_support_eliminations_pruned or 0) > 0,
    'learned exchange incompatibilities were not reused'
  )
  truthy((counters.search_calls or math.huge) < 200, 'value-routing learning regressed')
end

-- Pair provenance survives deterministic continuation subtrees. A rejection
-- reached through another bind, a guard, or an or_else fallback eliminates the
-- same producer-consumer activation pair only after the complete subtree is
-- locally closed.
if machine == 'ledger' then
  local wrappers = {
    delayed = function(value, expected)
      return Op.always(value):and_then(function(next_value)
        return next_value == expected and Op.always(next_value) or Op.never()
      end)
    end,
    guarded = function(value, expected)
      return Op.guard(function()
        return value == expected and Op.always(value) or Op.never()
      end)
    end,
    fallback = function(value, expected)
      local accepted = value == expected and Op.always(value) or Op.never()
      return Op.never():or_else(accepted)
    end,
  }
  for label, continuation in pairs(wrappers) do
    local count = 7
    local runtime = Runtime.new({ machine = 'ledger', choice_seed = 1, instrumentation = true })
    local rendezvous = Rendezvous.new('value-routing-provenance-' .. label)
    local result
    runtime:spawn_raw(function()
      local lanes = {}
      for value = 1, count do
        lanes[#lanes + 1] = rendezvous:put_op(value)
      end
      for slot = 1, count do
        local expected = count - slot + 1
        lanes[#lanes + 1] = rendezvous:get_op():and_then(function(value)
          return continuation(value, expected)
        end)
      end
      result = runtime:perform(Op.together(lanes))
    end, 'value-routing-provenance-' .. label)
    eq(runtime:run().tag, 'found')
    eq(runtime:run().tag, 'idle')
    truthy(result ~= nil, label .. ' value-routing transaction did not complete')
    local counters = runtime:instrumentation_report().counters
    truthy(
      (counters.exchange_support_eliminations_learned or 0) > 0,
      label .. ' continuation did not eliminate rejected exchange supports'
    )
    local limit = label == 'delayed' and 200 or label == 'guarded' and 120 or 800
    truthy(
      (counters.search_calls or math.huge) < limit,
      label .. ' continuation rejection regressed to permutation search'
    )
  end
end

-- A choice considered as a supplier must remain unresolved when another choice
-- ultimately supplies the demand. This preserves completeness: its
-- non-supplying alternative may still be required elsewhere in the product.
do
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
    runtime:perform(Op.each({
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

-- Closed exact binary exchange fragments are checked as parity relations.
-- Odd cycles are refuted by a verified contradiction witness; even cycles
-- remain ordinary satisfiable transactions.
if machine == 'ledger' then
  local function run_ring(count)
    local runtime = Runtime.new({ machine = 'ledger', instrumentation = true })
    local edges, done = {}, 0
    for i = 1, count do
      edges[i] = Rendezvous.new('binary-relation-edge-' .. tostring(count) .. '-' .. tostring(i))
    end
    for i = 1, count do
      local node, previous = i, ((i - 2) % count) + 1
      runtime:spawn_raw(function()
        local zero = Op.each({ edges[node]:put_op(node), edges[previous]:put_op(node) })
        local one = Op.each({ edges[node]:get_op(), edges[previous]:get_op() })
        runtime:perform(Op.choice(zero, one))
        done = done + 1
      end, 'binary-relation-node-' .. tostring(i))
    end
    local status = runtime:run()
    return runtime, status, done
  end

  local odd, odd_status, odd_done = run_ring(9)
  eq(odd_status.tag, 'quiescent')
  eq(odd_done, 0)
  local odd_counters = odd:instrumentation_report().counters
  truthy((odd_counters.binary_relation_failures or 0) >= 1, 'odd ring lacked relation witness')
  truthy((odd_counters.search_calls or math.huge) < 20, 'odd ring regressed to parity enumeration')

  local _, even_status, even_done = run_ring(8)
  eq(even_status.tag, 'found')
  eq(even_done, 8)
end

print('tests/kernel/test_exchange_choice_propagation.lua: ok')

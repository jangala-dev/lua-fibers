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

local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local Rendezvous = require('fibers.resource.rendezvous')
local Scalar = require('fibers.resource.scalar')

local function eq(actual, expected, message)
  if actual ~= expected then
    error(
      (message or 'values differ') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual),
      2
    )
  end
end

local function rejects(opts, name)
  local ok = pcall(Runtime.new, opts)
  if ok then
    error(name .. ' should reject a non-positive limit', 2)
  end
end

rejects({ search_total_limit = 0 }, 'search_total_limit')
rejects({ search_trail_limit = -1 }, 'search_trail_limit')
rejects({ search_depth_limit = 0 }, 'search_depth_limit')
rejects({ cycle_work_limit = 0 }, 'cycle_work_limit')
rejects({ cycle_focus_limit = 0 }, 'cycle_focus_limit')

local machine = Runtime.new().machine_name
if machine == 'reference' then
  print('tests/kernel/test_search_limits.lua: ok')
  return
end

local function atomic_dispatch(opts, n)
  opts = opts or {}
  opts.machine = 'ledger'
  opts.choice_seed = opts.choice_seed or 2
  opts.plan_reuse = false

  local rt = Runtime.new(opts)
  local workers = {}
  for worker = 1, n do
    workers[worker] = Rendezvous.new('search-limit-worker-' .. tostring(worker))
    local worker_id = worker
    rt:spawn_raw(function()
      rt:perform(workers[worker_id]:get_op())
    end, 'search-limit-worker-' .. tostring(worker))
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
  end, 'search-limit-dispatcher')
  return rt, rt:run()
end

local rt, status = atomic_dispatch({ search_total_limit = 5 }, 8)
eq(status.tag, 'pending')
eq(status.kind, 'budget')
eq(status.reason, 'search_total_limit')
eq(next(rt._search_sessions), nil, 'hard total limit must not retain an unresumable session')

rt, status = atomic_dispatch({ search_depth_limit = 4 }, 8)
eq(status.tag, 'pending')
eq(status.kind, 'budget')
eq(status.reason, 'search_depth_limit')
eq(next(rt._search_sessions), nil, 'hard depth limit must not retain an unresumable session')

rt, status = atomic_dispatch({ search_trail_limit = 10 }, 8)
eq(status.tag, 'pending')
eq(status.kind, 'budget')
eq(status.reason, 'search_trail_limit')
eq(next(rt._search_sessions), nil, 'hard trail limit must not retain an unresumable session')

rt, status = atomic_dispatch({
  search_total_limit = 1000,
  search_depth_limit = 100,
  search_trail_limit = 10000,
}, 8)
eq(status.tag, 'found', 'generous hard limits should not alter a valid search')
eq(rt:run().tag, 'idle')

-- Aggregate cycle work is shared across every focus attempted by one driver
-- call. It is a soft resumable boundary, unlike the per-session hard limits.
rt, status = atomic_dispatch({ cycle_work_limit = 5 }, 8)
eq(status.tag, 'pending')
eq(status.kind, 'budget')
eq(status.reason, 'cycle_work_limit')
if next(rt._search_sessions) == nil then
  error('cycle work limit should retain resumable session state', 2)
end
for _ = 1, 100 do
  status = rt:run()
  if status.tag == 'found' then
    break
  end
end
eq(status.tag, 'found', 'cycle-limited search should resume across driver calls')

-- A focus limit bounds broad all-focus scans even when each individual focus
-- would otherwise begin its own proof session.
local focus_rt = Runtime.new({ machine = 'ledger', cycle_focus_limit = 2, plan_reuse = false })
for i = 1, 8 do
  local blocked = Rendezvous.new('cycle-focus-' .. tostring(i))
  focus_rt:spawn_raw(function()
    focus_rt:perform(blocked:get_op())
  end, 'cycle-focus-' .. tostring(i))
end
local focus_status = focus_rt:run()
eq(focus_status.tag, 'pending')
eq(focus_status.kind, 'budget')
eq(focus_status.reason, 'cycle_focus_limit')

-- Ordinary bounded stepping remains resumable and identifies the soft quantum
-- rather than presenting it as a hard safety limit.
local bounded = Runtime.new({ machine = 'ledger', plan_reuse = false })
local result
bounded:spawn_raw(function()
  result = bounded:perform(Op.choice({ Op.always('a'), Op.always('b') }))
end, 'bounded-limit-reason')
eq(bounded:step({ max_work = 1 }).kind, 'started')
local budget = bounded:step({ max_work = 1 })
eq(budget.tag, 'pending')
eq(budget.kind, 'budget')
eq(budget.reason, 'search_quantum')
for _ = 1, 12 do
  if bounded:step({ max_work = 1 }).tag == 'found' then
    break
  end
end
bounded:run()
if result ~= 'a' and result ~= 'b' then
  error('bounded search did not resume to a valid result', 2)
end

-- Unknown blocks fallback only inside the dependency component whose preferred
-- absence it may invalidate. An unrelated expensive proof must not impose a
-- runtime-wide liveness barrier.
do
  local unknown_rt = Runtime.new({
    machine = 'ledger',
    search_limit = 10,
    plan_reuse = false,
    instrumentation = true,
  })
  local fallback_result
  unknown_rt:spawn_raw(function()
    fallback_result = unknown_rt:perform(Op.never():or_else(Op.always('fallback')))
  end, 'independent-unknown-fallback')

  local worker_count, workers = 8, {}
  for worker = 1, worker_count do
    workers[worker] = Rendezvous.new('independent-unknown-worker-' .. tostring(worker))
    local index = worker
    unknown_rt:spawn_raw(function()
      unknown_rt:perform(workers[index]:get_op())
    end, 'independent-unknown-worker-' .. tostring(worker))
  end
  unknown_rt:spawn_raw(function()
    local jobs = {}
    for job = 1, worker_count do
      local choices = {}
      for worker = 1, worker_count do
        choices[worker] = workers[worker]:put_op(job)
      end
      jobs[job] = Op.choice(choices)
    end
    unknown_rt:perform(Op.all(jobs))
  end, 'independent-unknown-positive-focus')

  local first = unknown_rt:run()
  eq(first.tag, 'found')
  eq(fallback_result, 'fallback', 'independent Unknown work must not block local fallback')
  local remaining = unknown_rt:run()
  eq(remaining.tag, 'pending')
  eq(remaining.kind, 'budget')
end

-- The same bounded uncertainty still blocks fallback when it belongs to the
-- same dependency component. The declared gate read recruits the expensive
-- positive focus because it could invalidate the gate-based absence proof.
do
  local unknown_rt = Runtime.new({
    machine = 'ledger',
    search_limit = 10,
    plan_reuse = false,
    instrumentation = true,
  })
  local gate = Scalar.new('closed', 'component-unknown-gate')
  local fallback_result
  unknown_rt:spawn_raw(function()
    fallback_result = unknown_rt:perform(gate:expect_op('open'):or_else(Op.always('fallback')))
  end, 'component-unknown-fallback')

  local worker_count, workers = 8, {}
  for worker = 1, worker_count do
    workers[worker] = Rendezvous.new('component-unknown-worker-' .. tostring(worker))
    local index = worker
    unknown_rt:spawn_raw(function()
      unknown_rt:perform(workers[index]:get_op())
    end, 'component-unknown-worker-' .. tostring(worker))
  end
  unknown_rt:spawn_raw(function()
    local jobs = { gate:read_op() }
    for job = 1, worker_count do
      local choices = {}
      for worker = 1, worker_count do
        choices[worker] = workers[worker]:put_op(job)
      end
      jobs[#jobs + 1] = Op.choice(choices)
    end
    unknown_rt:perform(Op.all(jobs))
  end, 'component-unknown-positive-focus')

  local status = unknown_rt:run()
  eq(status.tag, 'pending')
  eq(status.kind, 'budget')
  eq(fallback_result, nil, 'same-component Unknown must keep fallback uncommitted')
  local snapshot = unknown_rt:instrumentation_report()
  if (snapshot.counters.fallback_transitions or 0) == 0 then
    error('test did not construct a fallback candidate', 2)
  end
end

print('tests/kernel/test_search_limits.lua: ok')

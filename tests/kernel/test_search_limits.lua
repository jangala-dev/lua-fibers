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

local machine = os.getenv('FIBERS_MACHINE') or 'ledger'
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

print('tests/kernel/test_search_limits.lua: ok')

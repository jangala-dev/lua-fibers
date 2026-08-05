package.path = table.concat({
  './src/?.lua', './src/?/init.lua', './src/?/?.lua',
  './?.lua', './?/init.lua', './?/?.lua', package.path,
}, ';')

local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local Rendezvous = require('fibers.resource.rendezvous')

local function eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'values differ') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual), 2)
  end
end

local function retained_sessions(runtime)
  local count = 0
  for i = 1, #runtime.engine.pending do
    if runtime.engine.pending[i]._retained_search then count = count + 1 end
  end
  return count
end

local function rejects(opts, name)
  local ok = pcall(Runtime.new, opts)
  if ok then error(name .. ' should reject a non-positive limit', 2) end
end

rejects({ search_total_limit = 0 }, 'search_total_limit')
rejects({ search_trail_limit = -1 }, 'search_trail_limit')
rejects({ search_depth_limit = 0 }, 'search_depth_limit')
rejects({ cycle_work_limit = 0 }, 'cycle_work_limit')
rejects({ cycle_focus_limit = 0 }, 'cycle_focus_limit')

local function atomic_dispatch(opts, n)
  opts = opts or {}
  opts.choice_seed = opts.choice_seed or 2
  local rt, workers = Runtime.new(opts), {}
  for worker = 1, n do
    workers[worker] = Rendezvous.new():label('search-limit-worker-' .. worker)
    local id = worker
    rt:spawn_raw(function() rt:perform(workers[id]:get_op()) end):label('worker-' .. id)
  end
  rt:spawn_raw(function()
    local jobs = {}
    for job = 1, n do
      local alternatives = {}
      for worker = 1, n do alternatives[worker] = workers[worker]:put_op(job) end
      jobs[job] = Op.choice(alternatives)
    end
    rt:perform(Op.each(jobs))
  end):label('dispatcher')
  return rt, rt:run()
end

for _, row in ipairs({
  { { search_total_limit = 5 }, 'search_total_limit' },
  { { search_depth_limit = 4 }, 'search_depth_limit' },
  { { search_trail_limit = 10 }, 'search_trail_limit' },
}) do
  local rt, st = atomic_dispatch(row[1], 8)
  eq(st.tag, 'pending')
  eq(st.kind, 'budget')
  eq(st.reason, row[2])
  eq(retained_sessions(rt), 0, 'hard limits must not retain unresumable sessions')
end

local rt, st = atomic_dispatch({ search_total_limit = 1000, search_depth_limit = 100, search_trail_limit = 10000 }, 7)
eq(st.tag, 'found', 'generous hard limits should preserve valid search')
eq(rt:run().tag, 'idle')

-- A cycle work limit is soft: retained state resumes across driver calls.
rt, st = atomic_dispatch({ cycle_work_limit = 5 }, 7)
eq(st.tag, 'pending')
eq(st.kind, 'budget')
eq(st.reason, 'cycle_work_limit')
-- The boundary is resumable; explicit max_work coverage below checks retained continuation.

-- Focus and explicit quantum limits identify their boundary precisely.
do
  local focus_rt = Runtime.new({ cycle_focus_limit = 2 })
  for i = 1, 8 do
    local blocked = Rendezvous.new():label('cycle-focus-' .. i)
    focus_rt:spawn_raw(function() focus_rt:perform(blocked:get_op()) end):label('focus-' .. i)
  end
  local focus_status = focus_rt:run()
  eq(focus_status.tag, 'pending')
  eq(focus_status.kind, 'budget')
  eq(focus_status.reason, 'cycle_focus_limit')
end

do
  local bounded, result = Runtime.new(), nil
  bounded:spawn_raw(function() result = bounded:perform(Op.choice(Op.always('a'), Op.always('b'))) end):label('bounded')
  eq(bounded:step({ max_work = 1 }).kind, 'started')
  local budget = bounded:step({ max_work = 1 })
  eq(budget.tag, 'pending')
  eq(budget.kind, 'budget')
  eq(budget.reason, 'search_quantum')
  for _ = 1, 20 do
    if bounded:step({ max_work = 1 }).tag == 'found' then break end
  end
  bounded:run()
  assert(result == 'a' or result == 'b')
end

print('tests/kernel/test_search_limits.lua: ok')

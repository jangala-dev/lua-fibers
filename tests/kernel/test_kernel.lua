package.path = table.concat({
  './src/?.lua', './src/?/init.lua', './src/?/?.lua',
  './?.lua', './?/init.lua', './?/?.lua', package.path,
}, ';')

local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local Rendezvous = require('fibers.resource.rendezvous')
local Journal = require('fibers.internal.kernel.journal')

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

local trail = Journal.new()
local value = { item = 'baseline' }
local outer = trail:mark()
trail:set(value, 'item', 'outer')
local inner = trail:mark()
trail:set(value, 'item', 'inner')
trail:accept(inner)
eq(value.item, 'inner')
trail:rollback(outer)
eq(value.item, 'baseline')
local accepted = trail:mark()
trail:set(value, 'item', 'accepted')
trail:accept(accepted)
local later = trail:mark()
trail:set(value, 'item', 'later')
trail:rollback(later)
eq(value.item, 'accepted')

local rt = Runtime.new()
eq(rt.engine.proof_graph, nil, 'frontier index should be demand-driven')

local result
rt:spawn_raw(function()
  result = rt:perform(Op.always(2):and_then(Op.guard(function(value)
    return Op.always(value * 3)
  end)))
end, 'small-kernel-basic')
eq(rt:run().tag, 'found')
eq(result, 6)
eq(rt:run().tag, 'idle')
eq(rt.engine.proof_graph, nil, 'closed positive work should not allocate a frontier index')

local blocked = Runtime.new()
local blocked_channel = Rendezvous.new('lazy-frontier-index')
blocked:spawn_raw(function() blocked:perform(blocked_channel:get_op()) end)
local blocked_status = blocked:run().tag
assert(blocked_status == 'pending' or blocked_status == 'quiescent')
eq(type(blocked.engine.proof_graph), 'table', 'blocked proof should allocate a frontier index')

local function dispatch(opts, count)
  opts = opts or {}
  opts.choice_seed = 2
  if opts.instrumentation == nil then opts.instrumentation = true end
  local runtime = Runtime.new(opts)
  local workers = {}
  for worker = 1, count do
    workers[worker] = Rendezvous.new('small-limit-worker-' .. tostring(worker))
    local index = worker
    runtime:spawn_raw(function()
      runtime:perform(workers[index]:get_op())
    end, 'small-limit-worker-' .. tostring(worker))
  end
  runtime:spawn_raw(function()
    local jobs = {}
    for job = 1, count do
      local choices = {}
      for worker = 1, count do choices[worker] = workers[worker]:put_op(job) end
      jobs[job] = Op.choice(choices)
    end
    runtime:perform(Op.each(jobs))
  end, 'small-limit-dispatcher')
  return runtime, runtime:run()
end

local limited, status = dispatch({ search_total_limit = 5 }, 3)
eq(status.tag, 'pending')
eq(status.kind, 'budget')
eq(status.reason, 'search_total_limit')
eq(retained_sessions(limited), 0)

limited, status = dispatch({ search_depth_limit = 2 }, 3)
eq(status.tag, 'pending')
eq(status.reason, 'search_depth_limit')

limited, status = dispatch({ search_trail_limit = 5 }, 3)
eq(status.tag, 'pending')
eq(status.reason, 'search_trail_limit')

local complete
complete, status = dispatch({
  search_total_limit = 1000,
  search_depth_limit = 100,
  search_trail_limit = 10000,
}, 3)
eq(status.tag, 'found')
eq(complete:run().tag, 'idle')

-- Deferred choices are ranked against the concrete partner frontier. This is
-- generic ordering rather than a matching solver: every alternative remains
-- available to exhaustive backtracking, but an ordinary all-different dispatch
-- should propagate without factorial enumeration.
local ranked, ranked_status = dispatch({
  search_total_limit = 10000,
  search_depth_limit = 100,
  search_trail_limit = 100000,
}, 16)
eq(ranked_status.tag, 'found')
eq(ranked:run().tag, 'idle')
local ranked_counters = (ranked.instrumentation and ranked.instrumentation:report()).counters
eq((ranked_counters.search_calls or math.huge) < 400, true, 'ranked dispatch expanded excessively')

local function replicated_ring(count)
  local runtime = Runtime.new({
    choice_seed = 2,
    instrumentation = true,
  })
  local primary, backup, results = {}, {}, {}
  for i = 1, count do
    primary[i] = Rendezvous.new('small-ring-primary-' .. tostring(i))
    backup[i] = Rendezvous.new('small-ring-backup-' .. tostring(i))
  end
  for i = 1, count do
    local node, previous = i, ((i - 2) % count) + 1
    runtime:spawn_raw(function()
      local p = Op.each({
        primary[node]:put_op(node),
        primary[previous]:get_op(),
      }):map(function(rows) return 'primary', rows[2][1] end)
      local b = Op.each({
        backup[node]:put_op(node),
        backup[previous]:get_op(),
      }):map(function(rows) return 'backup', rows[2][1] end)
      results[node] = { runtime:perform(Op.choice(p, b)) }
    end, 'small-ring-node-' .. tostring(i))
  end
  local status = runtime:run()
  return runtime, status, results
end

local ring, ring_status, ring_results = replicated_ring(8)
eq(ring_status.tag, 'found')
eq(ring:run().tag, 'idle')
local route = ring_results[1] and ring_results[1][1]
eq(route == 'primary' or route == 'backup', true, 'ring did not choose a route')
for i = 1, #ring_results do eq(ring_results[i][1], route, 'ring route diverged') end
local ring_counters = (ring.instrumentation and ring.instrumentation:report()).counters
eq((ring_counters.search_calls or math.huge) < 100, true, 'ranked ring expanded excessively')

print('tests/kernel/test_kernel.lua: ok')

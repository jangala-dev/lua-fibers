-- Adversarial but application-shaped proof-search workloads for Fibers.
--
-- Each invocation runs one isolated scenario so external harnesses may impose a
-- wall-clock limit without losing results from other cases.

package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

local Runtime = require('fibers.runtime')
local Rendezvous = require('fibers.resource.rendezvous')
local Op = require('fibers.op')
local Clock = require('performance.clock')

local function parse_args(values)
  local out = {
    case = 'priority-fallback',
    size = 8,
    seed = 1,
    search_limit = 1000000,
    search_total_limit = nil,
    search_depth_limit = nil,
    search_trail_limit = nil,
    instrumentation = true,
  }
  local i = 1
  while i <= #values do
    local key = values[i]
    if key == '--case' then
      out.case = assert(values[i + 1], '--case requires a value')
      i = i + 2
    elseif key == '--size' then
      out.size = assert(tonumber(values[i + 1]), '--size requires a number')
      i = i + 2
    elseif key == '--seed' then
      out.seed = assert(tonumber(values[i + 1]), '--seed requires a number')
      i = i + 2
    elseif key == '--no-instrumentation' then
      out.instrumentation = false
      i = i + 1
    elseif key == '--search-limit' then
      out.search_limit = assert(tonumber(values[i + 1]), '--search-limit requires a number')
      i = i + 2
    elseif key == '--search-total-limit' then
      out.search_total_limit = assert(tonumber(values[i + 1]), '--search-total-limit requires a number')
      i = i + 2
    elseif key == '--search-depth-limit' then
      out.search_depth_limit = assert(tonumber(values[i + 1]), '--search-depth-limit requires a number')
      i = i + 2
    elseif key == '--search-trail-limit' then
      out.search_trail_limit = assert(tonumber(values[i + 1]), '--search-trail-limit requires a number')
      i = i + 2
    else
      error('unknown argument: ' .. tostring(key))
    end
  end
  out.size = math.max(1, math.floor(out.size))
  out.seed = math.floor(out.seed)
  out.search_limit = math.max(1, math.floor(out.search_limit))
  if out.search_total_limit then
    out.search_total_limit = math.max(1, math.floor(out.search_total_limit))
  end
  if out.search_depth_limit then
    out.search_depth_limit = math.max(1, math.floor(out.search_depth_limit))
  end
  if out.search_trail_limit then
    out.search_trail_limit = math.max(1, math.floor(out.search_trail_limit))
  end
  return out
end

local function new_runtime(options)
  return Runtime.new({
    choice_seed = options.seed,
    search_limit = options.search_limit,
    search_total_limit = options.search_total_limit,
    search_depth_limit = options.search_depth_limit,
    search_trail_limit = options.search_trail_limit,
    instrumentation = options.instrumentation and {
      clock = Clock.now,
      slow_search_limit = 4,
      trace = false,
    } or nil,
  })
end

local function drive(rt)
  local calls = 0
  local status
  repeat
    status = rt:run()
    calls = calls + 1
  until status.tag ~= 'found'
  return status, calls
end

-- A batch dispatcher atomically assigns N jobs to N currently idle workers.
-- Every job can run on every worker.  It is a complete bipartite matching
-- expressed using ordinary choice, each, and rendezvous operations.
local function batch_dispatch(options)
  local n = options.size
  local rt = new_runtime(options)
  local workers, received = {}, {}

  for worker = 1, n do
    workers[worker] = Rendezvous.new():label('search-dispatch-worker-' .. tostring(worker))
    local worker_id = worker
    rt:spawn_raw(function()
      received[worker_id] = rt:perform(workers[worker_id]:get_op())
    end):label('search-dispatch-worker-' .. tostring(worker))
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
  end):label('search-dispatch-batch')

  local status, driver_calls = drive(rt)
  local seen = {}
  local valid = status.tag == 'idle'
  for worker = 1, n do
    local job = received[worker]
    if type(job) ~= 'number' or job < 1 or job > n or seen[job] then
      valid = false
    else
      seen[job] = true
    end
  end
  return rt, status, valid, driver_calls, 'perfect matching'
end

-- Replicated services choose primary or backup links for one atomic exchange.
-- A mixed route leaves unmatched neighbours, so a commit requires every node
-- around the ring to choose the same route.
local function replicated_ring(options)
  local n = options.size
  if n < 2 then
    error('replicated-ring requires size >= 2')
  end
  local rt = new_runtime(options)
  local primary, backup, received = {}, {}, {}
  for i = 1, n do
    primary[i] = Rendezvous.new():label('search-ring-primary-' .. tostring(i))
    backup[i] = Rendezvous.new():label('search-ring-backup-' .. tostring(i))
  end

  for i = 1, n do
    local node = i
    local previous = ((i - 2) % n) + 1
    rt:spawn_raw(function()
      local p = Op.each({
        primary[node]:put_op(node),
        primary[previous]:get_op(),
      }):map(function(rows)
        return 'primary', rows[2][1]
      end)
      local b = Op.each({
        backup[node]:put_op(node),
        backup[previous]:get_op(),
      }):map(function(rows)
        return 'backup', rows[2][1]
      end)
      received[node] = { rt:perform(Op.choice(p, b)) }
    end):label('search-ring-node-' .. tostring(i))
  end

  local status, driver_calls = drive(rt)
  local route = received[1] and received[1][1]
  local valid = status.tag == 'idle' and (route == 'primary' or route == 'backup')
  for i = 1, n do
    local expected = ((i - 2) % n) + 1
    valid = valid and received[i] ~= nil and received[i][1] == route and received[i][2] == expected
  end
  return rt, status, valid, driver_calls, route or 'none'
end

-- A consumer searches queues in priority order, falling back only after the
-- solver certifies that all earlier queues cannot currently supply a value.
local function priority_fallback(options)
  local n = options.size
  local rt = new_runtime(options)
  local queues = {}
  for i = 1, n do
    queues[i] = Rendezvous.new():label('search-priority-' .. tostring(i))
  end

  local selected = queues[1]:get_op()
  for i = 2, n do
    selected = selected:or_else(queues[i]:get_op())
  end

  local received
  rt:spawn_raw(function()
    received = rt:perform(selected)
  end):label('search-priority-consumer')
  rt:spawn_raw(function()
    rt:perform(queues[n]:put_op('last-queue'))
  end):label('search-priority-producer')

  local status, driver_calls = drive(rt)
  local valid = status.tag == 'idle' and received == 'last-queue'
  return rt, status, valid, driver_calls, 'last queue'
end

-- A large application may have many unrelated blocked services while one pair
-- is ready.  Component isolation should keep the active proof local even though
-- the driver must retain the unrelated requests.
local function idle_services(options)
  local n = options.size
  local rt = new_runtime(options)
  for i = 1, n do
    local idle = Rendezvous.new():label('search-idle-' .. tostring(i))
    rt:spawn_raw(function()
      rt:perform(idle:get_op())
    end):label('search-idle-service-' .. tostring(i))
  end

  local active = Rendezvous.new():label('search-active')
  local received
  rt:spawn_raw(function()
    received = rt:perform(active:get_op())
  end):label('search-active-consumer')
  rt:spawn_raw(function()
    rt:perform(active:put_op('ok'))
  end):label('search-active-producer')

  local status, driver_calls = drive(rt)
  local valid = status.tag == 'quiescent' and received == 'ok'
  return rt, status, valid, driver_calls, 'active pair amid idle services'
end

-- The same worker pool, but each job is dispatched in its own transaction.
-- This is the natural control for batch-dispatch and shows the cost of asking
-- the solver to find the whole perfect matching in one proof.
local function incremental_dispatch(options)
  local n = options.size
  local rt = new_runtime(options)
  local workers, received = {}, {}

  for worker = 1, n do
    workers[worker] = Rendezvous.new():label('search-incremental-worker-' .. tostring(worker))
    local worker_id = worker
    rt:spawn_raw(function()
      received[worker_id] = rt:perform(workers[worker_id]:get_op())
    end):label('search-incremental-worker-' .. tostring(worker))
  end

  rt:spawn_raw(function()
    for job = 1, n do
      local alternatives = {}
      for worker = 1, n do
        alternatives[worker] = workers[worker]:put_op(job)
      end
      rt:perform(Op.choice(alternatives))
    end
  end):label('search-incremental-dispatcher')

  local status, driver_calls = drive(rt)
  local seen = {}
  local valid = status.tag == 'idle'
  for worker = 1, n do
    local job = received[worker]
    if type(job) ~= 'number' or job < 1 or job > n or seen[job] then
      valid = false
    else
      seen[job] = true
    end
  end
  return rt, status, valid, driver_calls, 'incremental matching'
end

-- A control for replicated-ring: route selection has already been made by
-- configuration or a leader, so the proof contains the same global rendezvous
-- cycle without a per-node primary/backup branch.
local function fixed_ring(options)
  local n = options.size
  if n < 2 then
    error('fixed-ring requires size >= 2')
  end
  local rt = new_runtime(options)
  local links, received = {}, {}
  for i = 1, n do
    links[i] = Rendezvous.new():label('search-fixed-ring-' .. tostring(i))
  end
  for i = 1, n do
    local node = i
    local previous = ((i - 2) % n) + 1
    rt:spawn_raw(function()
      local rows = rt:perform(Op.each({
        links[node]:put_op(node),
        links[previous]:get_op(),
      }))
      received[node] = rows[2][1]
    end):label('search-fixed-ring-node-' .. tostring(i))
  end
  local status, driver_calls = drive(rt)
  local valid = status.tag == 'idle'
  for i = 1, n do
    valid = valid and received[i] == ((i - 2) % n) + 1
  end
  return rt, status, valid, driver_calls, 'fixed route'
end

local CASES = {
  ['batch-dispatch'] = batch_dispatch,
  ['incremental-dispatch'] = incremental_dispatch,
  ['replicated-ring'] = replicated_ring,
  ['fixed-ring'] = fixed_ring,
  ['priority-fallback'] = priority_fallback,
  ['idle-services'] = idle_services,
}

local function csv_escape(value)
  local text = tostring(value == nil and '' or value)
  if text:find('[,\n"]') then
    return '"' .. text:gsub('"', '""') .. '"'
  end
  return text
end

local options = parse_args(arg or {})
local scenario = assert(CASES[options.case], 'unknown case: ' .. tostring(options.case))
collectgarbage('collect')
local started = Clock.now()
local rt, status, valid, driver_calls, digest = scenario(options)
local elapsed = Clock.now() - started
local snapshot = (rt.instrumentation and rt.instrumentation:report()) or {}
local c, m = snapshot.counters or {}, snapshot.maxima or {}
local fields = {
  options.case,
  options.size,
  options.seed,
  options.machine,
  status.tag,
  status.kind or status.reason or '',
  valid and 'ok' or 'invalid',
  string.format('%.9f', elapsed),
  driver_calls,
  c.searches or 0,
  c.search_calls or 0,
  c.branches or 0,
  c.rollbacks or 0,
  c.trail_entries or 0,
  c.recruit_branches or 0,
  c.exclude_branches or 0,
  c.footprint_checks or 0,
  c.footprint_matches or 0,
  m.search_steps_per_search or 0,
  m.search_depth or 0,
  m.component_size or 0,
  m.roots or 0,
  m.intents or 0,
  m.trail_entries_live or 0,
  digest,
}
for i = 1, #fields do
  fields[i] = csv_escape(fields[i])
end
print(table.concat(fields, ','))

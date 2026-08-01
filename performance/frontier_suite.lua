-- Regression measurements for persistent versioned execution frontiers.

package.path = table.concat({
  './src/?.lua', './src/?/init.lua', './src/?/?.lua',
  './?.lua', './?/init.lua', './?/?.lua', package.path,
}, ';')

local Runtime = require('fibers.runtime')
local Rendezvous = require('fibers.resource.rendezvous')
local Cell = require('fibers.resource.cell')
local Op = require('fibers.op')

local function counter(runtime, name)
  return runtime.instrumentation and (runtime.instrumentation.counters[name] or 0) or 0
end

local output = os.getenv('FIBERS_FRONTIER_OUTPUT') or ''
local rows = {}
local function row(name, fields)
  fields.case = name
  rows[#rows + 1] = fields
end

local function blocked(status)
  return status.tag == 'pending' or status.tag == 'quiescent'
end

-- Re-driving an unchanged Retry should reuse the persistent frontier.
do
  local rt = Runtime.new({ instrumentation = true })
  local ch = Rendezvous.new('frontier-bench-retry')
  rt:spawn_raw(function() rt:perform(ch:get_op()) end)
  assert(blocked(rt:run()))
  local first_calls = counter(rt, 'search_calls')
  local started = os.clock()
  for _ = 1, 32 do assert(blocked(rt:run())) end
  row('unchanged_retry', {
    iterations = 32,
    search_calls = counter(rt, 'search_calls') - first_calls,
    searches = counter(rt, 'searches'),
    dirty = 0,
    turns = 0,
    seconds = os.clock() - started,
  })
end

-- A change on one location should not dirty unrelated persistent roots.
do
  local rt = Runtime.new({ instrumentation = true })
  local cells, ids = {}, {}
  for i = 1, 64 do
    cells[i] = Cell.new(0, 'frontier-bench-cell-' .. i)
    rt:spawn_raw(function() rt:perform(cells[i]:expect_op(1)) end)
  end
  assert(blocked(rt:run()))
  for i = 1, #rt.engine.pending do ids[i] = rt.engine.pending[i].id end
  rt:spawn_raw(function() rt:perform(cells[17]:write_op(1)) end)
  rt:_start_one()
  local dirty = 0
  for i = 1, #ids do if rt.engine.proof_graph.dirty[ids[i]] then dirty = dirty + 1 end end
  row('targeted_invalidation', {
    iterations = 64,
    search_calls = counter(rt, 'search_calls'),
    searches = counter(rt, 'searches'),
    dirty = dirty,
    turns = 0,
    seconds = 0,
  })
end

local function dispatch(count, max_work)
  local rt = Runtime.new({ choice_seed = 7, instrumentation = true })
  local workers = {}
  for i = 1, count do
    workers[i] = Rendezvous.new('frontier-bench-worker-' .. count .. '-' .. i)
    local worker = workers[i]
    rt:spawn_raw(function() rt:perform(worker:get_op()) end)
  end
  rt:spawn_raw(function()
    local jobs = {}
    for job = 1, count do
      local alternatives = {}
      for worker = 1, count do alternatives[worker] = workers[worker]:put_op(job) end
      jobs[job] = Op.choice(alternatives)
    end
    rt:perform(Op.each(jobs))
  end)
  local turns, started = 0, os.clock()
  while true do
    turns = turns + 1
    local status = rt:step({ max_work = max_work })
    if status.tag == 'found' then break end
    assert(turns < 100000, 'bounded dispatch did not complete')
  end
  return rt, turns, os.clock() - started
end

do
  local rt, turns, seconds = dispatch(8, 1)
  row('bounded_dispatch_8', {
    iterations = 8,
    search_calls = counter(rt, 'search_calls'),
    searches = counter(rt, 'searches'),
    dirty = 0,
    turns = turns,
    seconds = seconds,
  })
end

local headers = { 'case', 'iterations', 'search_calls', 'searches', 'dirty', 'turns', 'seconds' }
local lines = { table.concat(headers, ',') }
for i = 1, #rows do
  local values = {}
  for j = 1, #headers do values[j] = tostring(rows[i][headers[j]] or 0) end
  lines[#lines + 1] = table.concat(values, ',')
end
local text = table.concat(lines, '\n') .. '\n'
if output ~= '' then
  local file = assert(io.open(output, 'wb'))
  file:write(text)
  file:close()
else
  io.write(text)
end

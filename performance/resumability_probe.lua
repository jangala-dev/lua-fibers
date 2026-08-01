package.path = table.concat({
  './src/?.lua', './src/?/init.lua', './src/?/?.lua',
  './?.lua', './?/init.lua', './?/?.lua', package.path,
}, ';')

local Runtime = require('fibers.runtime')
local Rendezvous = require('fibers.resource.rendezvous')
local Op = require('fibers.op')

local function counter(runtime, name)
  return runtime.instrumentation and (runtime.instrumentation.counters[name] or 0) or 0
end

local function run(count, max_work)
  local rt = Runtime.new({ choice_seed = 7, instrumentation = true })
  local workers = {}
  for i = 1, count do
    workers[i] = Rendezvous.new('resume-probe-' .. count .. '-' .. i)
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

  local started, turns = os.clock(), 0
  if max_work then
    for _ = 1, 100000 do
      turns = turns + 1
      local status = rt:step({ max_work = max_work })
      if status.tag == 'found' then break end
    end
    rt:run()
  else
    rt:run()
  end
  return turns, counter(rt, 'search_calls'), counter(rt, 'searches'), os.clock() - started
end

print('count,mode,max_work,turns,search_calls,searches,elapsed_seconds')
for _, count in ipairs({ 4, 6, 8 }) do
  local turns, calls, searches, elapsed = run(count)
  print(('%d,one-shot,,%d,%d,%d,%.6f'):format(count, turns, calls, searches, elapsed))
  turns, calls, searches, elapsed = run(count, 1)
  print(('%d,bounded,1,%d,%d,%d,%.6f'):format(count, turns, calls, searches, elapsed))
end

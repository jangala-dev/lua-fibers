package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

-- spawn_op makes task admission part of the selected world. A committed desktop
-- indexing job starts exactly once; a losing full-rescan branch never starts.

local fibers = require('fibers')
local Op = require('fibers.op')

local jobs_started = 0
local index_result, decision

fibers.run(function(scope)
  local task = fibers.perform(scope:spawn_op(function()
    jobs_started = jobs_started + 1
    return 'workspace index ready'
  end, { name = 'workspace-index' }))

  index_result = task:await()
end)

fibers.run(function(scope)
  decision = fibers.perform(Op.choice(
    Op.always('keep cached search results'),
    scope
      :spawn_op(function()
        jobs_started = jobs_started + 1
        return 'full rescan completed'
      end, { name = 'losing-full-rescan' })
      :map(function()
        return 'replace the cache'
      end)
  ))
end, { choice_seed = 2 })

assert(index_result == 'workspace index ready')
assert(decision == 'keep cached search results')
assert(jobs_started == 1)
print('desktop index:', index_result)
print('decision:', decision, 'losing jobs started:', jobs_started - 1)

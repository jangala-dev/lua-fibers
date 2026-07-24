package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

-- spawn_op makes task admission part of the selected world. A committed spawn
-- starts exactly once; a losing spawn branch never starts at all.

local fibers = require('fibers')
local Op = require('fibers.op')

local starts = 0
local value, decision

fibers.run(function(scope)
  local task = fibers.perform(scope:spawn_op(function()
    starts = starts + 1
    return 42
  end, { name = 'committed-worker' }))

  value = task:await()
end)

fibers.run(function(scope)
  decision = fibers.perform(Op.choice(
    Op.always('keep the current plan'),
    scope
      :spawn_op(function()
        starts = starts + 1
        return 'should not run'
      end, { name = 'losing-worker' })
      :map(function()
        return 'spawned replacement'
      end)
  ))
end, { choice_seed = 2 })

assert(value == 42)
assert(decision == 'keep the current plan')
assert(starts == 1)
print('task value:', value, 'losing branch started:', starts - 1)

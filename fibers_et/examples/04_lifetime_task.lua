package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

-- Lifetime and Task: transactional lifetime management.
--
-- A Lifetime is the user-facing facility built over the Region ownership
-- ownership boundary. Spawning a task through a Lifetime is transactional: the task starts
-- only after admission commits.

local fibers = require('fibers')

local life = fibers.Lifetime.new('main')
local value

fibers.run(function()
  local task = fibers.perform(life:spawn_op(function()
    return 40 + 2
  end, { name = 'worker' }))

  value = fibers.perform(task:await_op())
  fibers.perform(life:retire_op(task))
end)

print('task result:', value)

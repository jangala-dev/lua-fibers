package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

-- Scope and Task: tasks are owned by the current scope.
--
-- The scope boundary accounts for the task before returning; ordinary code does
-- not manually retire scope roots.

local fibers = require('fibers')

local value

fibers.run(function()
  local task = fibers.spawn(function()
    return 40 + 2
  end, { name = 'worker' })

  value = fibers.perform(task:await_op())
end)

print('task result:', value)

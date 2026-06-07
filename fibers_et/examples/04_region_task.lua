package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

-- Region and Task: lifetime boundary plus owned running work.
--
-- Spawning a task through a Region is transactional.  The task starts after
-- admission commits, and join is just another operation.

local fibers = require('fibers')

local region = fibers.Region.new('main')
local status, value

fibers.run(function()
  local task = fibers.perform(region:spawn_op(function()
    return 40 + 2
  end, 'worker'))

  status, value = fibers.perform(task:join_op())
end)

print('task result:', status, value)

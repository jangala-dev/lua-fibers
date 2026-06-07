package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

-- Cell: transactional state.
--
-- A Cell update is journalled and becomes real only when its transaction
-- commits.  A wait operation produces a wait interest until the predicate is
-- true in a committed world.

local fibers = require('fibers')

local counter = fibers.Cell.new(0, 'counter')
local observed

fibers.run(function()
  fibers.spawn(function()
    fibers.perform(counter:update_op(function(n) return n + 1 end))
    fibers.perform(counter:update_op(function(n) return n + 1 end))
  end, 'incrementer')

  observed = fibers.perform(counter:wait_op(function(n)
    return n >= 2
  end))
end)

print('counter reached:', observed)

-- Cell callbacks are speculative: keep predicates and update functions pure.
-- Use Effect for committed external work.

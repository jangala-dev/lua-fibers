package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

-- Cell: transactional state.
--
-- Cell primitives read and write facts. Waiting and updating are ordinary Op
-- composition over read_op, write_op, snapshot_op and changed_op.

local fibers = require('fibers')

local function increment(cell)
  return cell:read_op():and_then(function(n)
    return cell:write_op(n + 1):map(function() return n + 1 end)
  end)
end

local function wait_until(cell, pred)
  local function loop()
    return cell:snapshot_op():and_then(function(s)
      if pred(s.value) then return fibers.always(s.value) end
      return cell:changed_op(s.version):and_then(function() return loop() end)
    end)
  end
  return loop()
end

local counter = fibers.Cell.new(0, 'counter')
local observed

fibers.run(function()
  fibers.spawn_raw(function()
    fibers.perform(increment(counter))
    fibers.perform(increment(counter))
  end, 'incrementer')

  observed = fibers.perform(wait_until(counter, function(n)
    return n >= 2
  end))
end)

print('counter reached:', observed)

-- The callbacks above are algebra callbacks. Use Effect for committed external work.

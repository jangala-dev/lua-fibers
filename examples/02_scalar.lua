package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './reference/?.lua',
  './reference/?/init.lua',
  './reference/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

-- Scalar: transactional state.
--
-- Scalar primitives read and write facts. Waiting and updating are ordinary Op
-- composition over read_op, write_op, snapshot_op and changed_op.

local fibers = require('fibers')

local function increment(scalar)
  return scalar:read_op():and_then(function(n)
    return scalar:write_op(n + 1):map(function()
      return n + 1
    end)
  end)
end

local function wait_until(scalar, pred)
  local function loop()
    return scalar:snapshot_op():and_then(function(s)
      if pred(s.value) then
        return fibers.always(s.value)
      end
      return scalar:changed_op(s.version):and_then(function()
        return loop()
      end)
    end)
  end
  return loop()
end

local counter = fibers.Scalar.new(0, 'counter')
local observed

fibers.run(function()
  fibers.spawn(function()
    fibers.perform(increment(counter))
    fibers.perform(increment(counter))
  end, 'incrementer')

  observed = fibers.perform(wait_until(counter, function(n)
    return n >= 2
  end))
end)

print('counter reached:', observed)

-- The callbacks above are algebra callbacks. Use Effect for committed external work.

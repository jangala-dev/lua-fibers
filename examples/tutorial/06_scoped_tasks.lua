package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

-- Tasks belong to a scope. The boundary accounts for children and retained
-- obligations before returning.

local fibers = require('fibers')

local value

fibers.run(function(scope)
  local task = scope:spawn(function()
    return 40 + 2
  end, 'worker')

  value = task:await()
end)

assert(value == 42)
print('task result:', value)

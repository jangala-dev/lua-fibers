package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

-- Scalar provides direct state operations and composable transactional forms.

local fibers = require('fibers')
local Scalar = require('fibers.resource.scalar')

local state = Scalar.new(0, 'counter')
local result

fibers.run(function()
  assert(state:read() == 0)
  state:write(1)

  result = fibers.perform(state:read_op():and_then(function(old)
    return state:write_op(old + 1):map(function()
      return old + 1
    end)
  end))
end)

assert(result == 2)
assert(state.value == 2)
print('state:', result)

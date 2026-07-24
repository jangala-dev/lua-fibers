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

local incident_level = Scalar.new(0, 'incident-level')
local escalated_level

fibers.run(function()
  assert(incident_level:read() == 0)
  incident_level:write(1)

  escalated_level = fibers.perform(incident_level:read_op():and_then(function(current_level)
    return incident_level:write_op(current_level + 1):map(function()
      return current_level + 1
    end)
  end))
end)

assert(escalated_level == 2)
assert(incident_level.value == 2)
print('incident level:', escalated_level)

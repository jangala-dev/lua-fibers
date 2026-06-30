package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

local fibers = require('fibers')

local flow = fibers.Flow.new({ capacity = 16, name = 'example-scalar-flow' })
local inlet, outlet = flow:inlet(), flow:outlet()

fibers.run(function()
  local rows = fibers.perform(fibers.tensor({
    inlet:write_op('hello'),
    outlet:read_op(5),
  }))
  assert(rows[1][1] == 5)
  assert(rows[2][1] == 'hello')
end)

print('scalar flow example ok')

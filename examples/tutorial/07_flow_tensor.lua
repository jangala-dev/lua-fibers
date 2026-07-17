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

local fibers = require('fibers')
local Flow = require('fibers.flow')
local flow = Flow.new({ capacity = 16, name = 'flow-tensor' })
local inlet, outlet = flow:inlet(), flow:outlet()

fibers.run(function()
  local rows = fibers.perform(fibers.tensor({
    inlet:write_op('hello'),
    outlet:read_some_op(5),
  }))
  assert(rows[1][1] == 5)
  assert(rows[2][1] == 'hello')
end)

print('examples/tutorial/07_flow_tensor.lua: ok')

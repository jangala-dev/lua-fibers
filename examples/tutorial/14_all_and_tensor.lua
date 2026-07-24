package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

-- all combines requirements which must each be independently supportable.
-- tensor additionally permits intentional positive supply between siblings.

local fibers = require('fibers')
local Op = require('fibers.op')
local Counter = require('fibers.resource.counter')
local Flow = require('fibers.resource.flow')

local left = Counter.new({ initial = 1, name = 'left-stock' })
local right = Counter.new({ initial = 1, name = 'right-stock' })
local flow = Flow.new({ capacity = 16, name = 'handoff' })

fibers.run(function()
  fibers.perform(Op.all({
    left:take_op(1),
    right:take_op(1),
  }))

  local rows = fibers.perform(Op.tensor({
    flow:inlet():write_op('hello'),
    flow:outlet():read_some_op(5),
  }))

  assert(rows[1][1] == 5)
  assert(rows[2][1] == 'hello')
end)

assert(left.value == 0 and right.value == 0)
print('all reserved both stocks; tensor handed off hello')

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
local Op = require('fibers.op')
local Flow = require('fibers.resource.flow')

local n = tonumber(arg[1]) or 2000
local mode = arg[2] or 'sequential'
local flow = Flow.new(64, 'bench-flow')
local inlet, outlet = flow:inlet(), flow:outlet()
local total = 0
fibers.run(function()
  if mode == 'sequential' then
    for _ = 1, n do
      total = total + fibers.perform(inlet:write_op('abcdefgh'))
      total = total + #fibers.perform(outlet:read_exactly_op(8))
    end
  elseif mode == 'tensor' then
    for _ = 1, n do
      local rows = fibers.perform(Op.tensor({ inlet:write_op('abcdefgh'), outlet:read_exactly_op(8) }))
      total = total + rows[1][1] + #rows[2][1]
    end
  elseif mode == 'fill' then
    for _ = 1, n do
      fibers.perform(inlet:write_op('x'))
    end
    total = #fibers.perform(outlet:read_exactly_op(n))
    assert(total == n)
    print(total)
    return
  else
    error('unknown mode: ' .. tostring(mode))
  end
end)
assert(total == n * 16)
print(total)

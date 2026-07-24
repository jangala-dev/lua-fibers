package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

-- Start with ordinary sequential code. Fibres suspend at direct operations, and
-- the enclosing scope accounts for every child before it returns.

local fibers = require('fibers')
local channel = require('fibers.channel')

local jobs = channel.new()
local replies = channel.new()
local result

fibers.run(function(scope)
  scope:spawn(function()
    local job = jobs:get()
    replies:put('completed ' .. job)
  end, 'worker')

  jobs:put('inspection')
  result = replies:get()
end)

assert(result == 'completed inspection')
print('result:', result)

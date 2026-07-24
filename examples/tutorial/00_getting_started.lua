package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

-- Start with ordinary sequential code. The worker suspends until a command
-- arrives, and the enclosing scope accounts for the child before it returns.

local fibers = require('fibers')
local channel = require('fibers.channel')

local commands = channel.new()
local results = channel.new()
local result

fibers.run(function(scope)
  scope:spawn(function()
    local command = commands:get()
    results:put('completed ' .. command)
  end, 'command-worker')

  commands:put('refresh configuration')
  result = results:get()
end)

assert(result == 'completed refresh configuration')
print('worker:', result)

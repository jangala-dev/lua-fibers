package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

-- choice says that either coherent result is acceptable. Source order does not
-- create priority.

local fibers = require('fibers')
local Op = require('fibers.op')
local Sleep = require('fibers.sleep')
local channel = require('fibers.channel')
local Host = require('fibers.host')

local inbox = channel.new()
local result

fibers.run(function(scope)
  scope:spawn(function()
    Sleep.sleep(2)
    inbox:put('late message')
  end, 'delayed-sender')

  result = fibers.perform(Op.choice(
    inbox:get_op(),
    Sleep.sleep_op(1):map(function()
      return 'timeout'
    end)
  ))

  -- The sender remains owned by the scope. Drain it so this example exits
  -- normally rather than cancelling it at the boundary.
  if result == 'timeout' then
    assert(inbox:get() == 'late message')
  end
end, { host = Host.manual() })

assert(result == 'timeout')
print('choice result:', result)

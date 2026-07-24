package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

-- Named combinators retain the readability of the decision in its result.
-- named_choice returns the selected branch name followed by its values;
-- named_all returns a table keyed like its input.

local fibers = require('fibers')
local Op = require('fibers.op')
local Sleep = require('fibers.sleep')
local channel = require('fibers.channel')
local Host = require('fibers.host')

local inbox = channel.new()
local selected, message, total

fibers.run(function(scope)
  scope:spawn(function()
    inbox:put('ready')
  end, 'sender')

  selected, message = fibers.perform(Op.named_choice({
    message = inbox:get_op(),
    timeout = Sleep.sleep_op(5):map(function()
      return 'no message'
    end),
  }))

  local values = fibers.perform(Op.named_all({
    base = Op.always(40),
    increment = Op.always(2),
  }))
  total = values.base + values.increment
end, { host = Host.manual() })

assert(selected == 'message')
assert(message == 'ready')
assert(total == 42)
print('selected:', selected, message, 'total:', total)

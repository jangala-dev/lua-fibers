package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

-- and_then carries a provisional result into the next option. The reservation
-- and send below form one transaction; no compensation code is required.

local fibers = require('fibers')
local channel = require('fibers.channel')
local Counter = require('fibers.resource.counter')

local slots = Counter.new({ initial = 1, name = 'worker-slots' })
local requests = channel.new()
local received, outcome

fibers.run(function(scope)
  scope:spawn(function()
    received = requests:get()
  end, 'receiver')

  outcome = fibers.perform(slots
    :take_op(1)
    :and_then(function()
      return requests:put_op('inspection')
    end)
    :map(function()
      return 'admitted'
    end))
end)

assert(outcome == 'admitted')
assert(received == 'inspection')
assert(slots.value == 0)
print('transaction:', outcome)

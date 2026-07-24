package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

-- or_else is semantic priority. The fallback opens only after the preferred
-- transaction has a valid present refutation. Earlier provisional work is then
-- retracted.

local fibers = require('fibers')
local Op = require('fibers.op')
local channel = require('fibers.channel')
local Counter = require('fibers.resource.counter')

local slots = Counter.new({ initial = 1, name = 'slots' })
local requests = channel.new()
local first, second, received

local function dispatch_op()
  return slots
    :take_op(1)
    :and_then(function()
      return requests:put_op('inspection')
    end)
    :map(function()
      return 'dispatched'
    end)
end

fibers.run(function(scope)
  -- No receiver exists, so the complete preferred transaction is absent. The
  -- provisional slot take is rolled back before the fallback commits.
  first = fibers.perform(dispatch_op():or_else(Op.always('unavailable')))
  assert(slots.value == 1)

  scope:spawn(function()
    received = requests:get()
  end, 'receiver')

  second = fibers.perform(dispatch_op():or_else(Op.always('unavailable')))
end)

assert(first == 'unavailable')
assert(second == 'dispatched')
assert(received == 'inspection')
assert(slots.value == 0)
print('without receiver:', first, 'with receiver:', second)

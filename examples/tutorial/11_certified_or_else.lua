package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

-- or_else is semantic priority. The captain flanks only when the complete
-- order can be delivered; otherwise the provisional stamina spend is retracted
-- before the hold-position fallback commits.

local fibers = require('fibers')
local Op = require('fibers.op')
local channel = require('fibers.channel')
local Counter = require('fibers.resource.counter')

local stamina = Counter.new(1):label('captain-stamina')
local squad_orders = channel.new()
local first_order, second_order, delivered_order

local function flank_op()
  return stamina
    :take_op(1)
    :and_then(squad_orders:put_op('flank the eastern stair'))
    :map(function()
      return 'flanking'
    end)
end

fibers.run(function(scope)
  first_order = fibers.perform(flank_op():or_else(Op.always('hold position')))
  assert(stamina.value == 1)

  scope:spawn(function()
    delivered_order = squad_orders:get()
  end):label('squad-radio')

  second_order = fibers.perform(flank_op():or_else(Op.always('hold position')))
end)

assert(first_order == 'hold position')
assert(second_order == 'flanking')
assert(delivered_order == 'flank the eastern stair')
assert(stamina.value == 0)
print('without radio:', first_order)
print('with radio:', second_order, '-', delivered_order)

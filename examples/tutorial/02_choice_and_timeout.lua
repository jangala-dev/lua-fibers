package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

-- choice says that either coherent result is acceptable. A flood sensor may
-- confirm an alarm, or the emergency controller may proceed on precaution.

local fibers = require('fibers')
local Op = require('fibers.op')
local Sleep = require('fibers.sleep')
local channel = require('fibers.channel')
local Host = require('fibers.host')

local confirmations = channel.new()
local result

fibers.run(function(scope)
  scope:spawn(function()
    Sleep.sleep(2)
    confirmations:put('river sensor confirmed')
  end, 'late-sensor-confirmation')

  result = fibers.perform(Op.choice(
    confirmations:get_op(),
    Sleep.sleep_op(1):map(function()
      return 'dispatch on precautionary threshold'
    end)
  ))

  -- The late producer remains in the Scope's custody. Drain its message so this
  -- example exits normally rather than cancelling the child at the boundary.
  if result == 'dispatch on precautionary threshold' then
    assert(confirmations:get() == 'river sensor confirmed')
  end
end, { host = Host.manual() })

assert(result == 'dispatch on precautionary threshold')
print('emergency decision:', result)

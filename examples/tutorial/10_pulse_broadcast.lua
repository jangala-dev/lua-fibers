package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

-- Pulse is a coalescing broadcast notification. Every waiter observes that the
-- logical version advanced; the signal does not have to be consumed by one of
-- them.

local fibers = require('fibers')
local Pulse = require('fibers.pulse')

local observed = {}

fibers.run(function(scope)
  local changed = Pulse.new({ name = 'configuration-changed' })

  local first = scope:spawn(function()
    return changed:changed(0)
  end, 'first-waiter')

  local second = scope:spawn(function()
    return changed:changed(0)
  end, 'second-waiter')

  assert(changed:signal() == 1)
  observed[1] = first:await()
  observed[2] = second:await()

  changed:close('configuration source stopped')
  local version, reason = changed:changed(1)
  observed[3], observed[4] = version, reason
end)

assert(observed[1] == 1 and observed[2] == 1)
assert(observed[3] == nil and observed[4] == 'configuration source stopped')
print('broadcast version:', observed[1], observed[2], 'closed:', observed[4])

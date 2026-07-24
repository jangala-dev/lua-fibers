package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

-- Pulse is a coalescing broadcast notification. The shelter radio and warning
-- beacon both notice that the hazard picture changed; neither consumes the
-- notification from the other.

local fibers = require('fibers')
local Pulse = require('fibers.pulse')

local observed = {}

fibers.run(function(scope)
  local hazard_changed = Pulse.new({ name = 'shelter-hazard-changed' })

  local radio = scope:spawn(function()
    return hazard_changed:changed(0)
  end, 'shelter-radio')

  local beacon = scope:spawn(function()
    return hazard_changed:changed(0)
  end, 'warning-beacon')

  assert(hazard_changed:signal() == 1)
  observed[1] = radio:await()
  observed[2] = beacon:await()

  hazard_changed:close('incident controller stood down')
  local version, reason = hazard_changed:changed(1)
  observed[3], observed[4] = version, reason
end)

assert(observed[1] == 1 and observed[2] == 1)
assert(observed[3] == nil and observed[4] == 'incident controller stood down')
print('hazard version:', observed[1], observed[2], 'closed:', observed[4])

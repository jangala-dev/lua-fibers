package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

-- on_defeat attaches a typed committed obligation to a competing occurrence.
-- When the cautious robot route wins, the incompatible high-speed trajectory
-- is retired as part of the same decision.

local fibers = require('fibers')
local Op = require('fibers.op')
local Effect = require('fibers.effect')

local retired_trajectories = {}
local RetireTrajectoryKind

RetireTrajectoryKind = Effect.kind({
  name = 'tutorial.retire-robot-trajectory',
  key = function(payload)
    return payload.trajectory
  end,
  merge = function(first, _second)
    return first
  end,
  prepare = function(_runtime, payload)
    return {
      kind = RetireTrajectoryKind,
      payload = payload,
      discharge = function(_runtime, prepared)
        retired_trajectories[#retired_trajectories + 1] = prepared.payload.trajectory
      end,
    }
  end,
})

local selected_route
fibers.run(function()
  local retire_fast_route = Effect.of(RetireTrajectoryKind, {
    trajectory = 'high-speed-loading-bay-route',
  })
  selected_route = fibers.perform(
    Op.choice(
      Op.always('cautious-service-corridor-route'),
      Op.always('high-speed-loading-bay-route'):on_defeat(retire_fast_route)
    )
  )
end, { choice_seed = 2 })

assert(selected_route == 'cautious-service-corridor-route')
assert(retired_trajectories[1] == 'high-speed-loading-bay-route')
print('selected:', selected_route, 'retired:', retired_trajectories[1])

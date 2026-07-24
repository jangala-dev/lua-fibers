package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

-- The callback phases are part of the programming model:
--   1. map/and_then/guards construct possible worlds and must remain pure;
--   2. effect prepare is pure, then discharge runs after commitment;
--   3. wrap resumes the participant and may perform ordinary presentation.

local fibers = require('fibers')
local Op = require('fibers.op')
local Effect = require('fibers.effect')

local timeline = {}
local DispatchAlertKind

DispatchAlertKind = Effect.kind({
  name = 'tutorial.dispatch-alert',
  key = function(payload)
    return payload.incident_id
  end,
  merge = function(first, _second)
    return first
  end,
  prepare = function(_runtime, payload)
    -- Pure: describe the post-commit plan only. Do not page responders here.
    return {
      kind = DispatchAlertKind,
      payload = payload,
      discharge = function(_runtime, prepared)
        timeline[#timeline + 1] = 'effect: page ' .. prepared.payload.team
      end,
    }
  end,
})

local alert
fibers.run(function()
  local dispatch = Effect.of(DispatchAlertKind, {
    incident_id = 'river-rise-17',
    team = 'river response team',
  })

  alert = fibers.perform(Op.emit(dispatch)
    :map(function()
      return 'alert selected' -- speculative and pure
    end)
    :wrap(function(selected)
      timeline[#timeline + 1] = 'wrap: update operations dashboard'
      return selected
    end))
end)

assert(alert == 'alert selected')
assert(table.concat(timeline, ',') == 'effect: page river response team,wrap: update operations dashboard')
print(table.concat(timeline, ' then '))

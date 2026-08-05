-- A controlled manual embedding makes the buffering policies observable.
-- Several engine firings are queued before one Application:advance call:
--
--   events  preserves every payload;
--   latest  keeps only the newest unconsumed payload;
--   pulse   keeps only the newest logical generation.

local ReplicatedStorage = game:GetService('ReplicatedStorage')
local Packages = ReplicatedStorage:WaitForChild('Packages')
local FibersPackage = Packages:WaitForChild('Fibers')

local Roblox = require(FibersPackage.roblox)

local actionSignal = Instance.new('BindableEvent')
local healthSignal = Instance.new('BindableEvent')
local navigationInvalidated = Instance.new('BindableEvent')

local app = Roblox.prepare(function()
  local actions = Roblox.events(actionSignal.Event, {
    name = 'every-player-action',
  })
  local health = Roblox.latest(healthSignal.Event, {
    name = 'newest-health',
  })
  local navigation = Roblox.pulse(navigationInvalidated.Event, {
    name = 'navigation-invalidated',
  })

  local firstAction = actions:next()
  local secondAction = actions:next()
  local thirdAction = actions:next()
  local newestHealth = health:next()
  local navigationGeneration = navigation:next()

  assert(firstAction == 'light-attack')
  assert(secondAction == 'heavy-attack')
  assert(thirdAction == 'dodge')
  assert(newestHealth == 60)
  assert(navigationGeneration == 3)

  print('queued actions', firstAction, secondAction, thirdAction)
  print('newest health', newestHealth)
  print('navigation generation', navigationGeneration)
end, {
  name = 'controlled-signal-modes',
  max_steps_per_turn = 128,
  max_work_per_step = 512,
})

local function advance_until_boundary()
  for _ = 1, 64 do
    local status = app:advance({
      horizon = os.clock() + 0.001,
    })
    if status.state == 'settled' or not status.needs_immediate_resume then
      return status
    end
  end
  error('Fibers did not reach a host boundary within the example turn limit')
end

-- First let the root create all three subscriptions and suspend on its first
-- read. The application is manual, so arriving signals remain queued until the
-- next explicit advance.
local initial = advance_until_boundary()
assert(initial.state == 'pending')

-- Every action is retained.
actionSignal:Fire('light-attack')
actionSignal:Fire('heavy-attack')
actionSignal:Fire('dodge')

-- Only 60 remains pending when the fiber asks for the latest health value.
healthSignal:Fire(100)
healthSignal:Fire(75)
healthSignal:Fire(60)

-- Three invalidations become one pending observation carrying generation 3.
navigationInvalidated:Fire('door-opened')
navigationInvalidated:Fire('bridge-lowered')
navigationInvalidated:Fire('obstacle-moved')

local final = advance_until_boundary()
assert(final.state == 'settled')

local result = app:result()
app:close()

actionSignal:Destroy()
healthSignal:Destroy()
navigationInvalidated:Destroy()

if not result.ok then
  error('Signal-mode example failed: ' .. tostring(result.primary))
end

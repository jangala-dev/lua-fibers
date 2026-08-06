-- Convenience phase scheduling above Application:advance. Ordinary signal
-- callbacks queue facts; Fibers advances after the selected Heartbeat boundary.
-- Place this LocalScript beneath a ScreenGui containing a TextButton named
-- DodgeButton.

local RunService = game:GetService('RunService')
local ReplicatedStorage = game:GetService('ReplicatedStorage')
local Packages = ReplicatedStorage:WaitForChild('Packages')
local FibersPackage = Packages:WaitForChild('Fibers')

local Roblox = require(FibersPackage.roblox)

local dodgeButton = script.Parent:WaitForChild('DodgeButton')

local app
app = Roblox.attach(function()
  local dodges = Roblox.events(dodgeButton.Activated, {
    label = 'dodge-input',
  })

  dodges:next()
  print('Dodge accepted at the next bounded Heartbeat turn')
end, {
  label = 'phase-driven-input',
  scheduling = 'phase',
  phase = RunService.Heartbeat,
  max_seconds_per_turn = 0.001,
  on_status = function(status)
    if status.state == 'settled' and app then
      local result = app:result()
      app:close()
      if not result.ok then
        warn('Fibers application failed', result)
      end
    end
  end,
})

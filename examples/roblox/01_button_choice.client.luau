-- Event-driven attachment: Roblox wakes Fibers only for a queued signal,
-- deadline or retained immediate work. No Heartbeat polling is required.
--
-- Place this LocalScript beneath a ScreenGui containing a TextButton named
-- ContinueButton.

local ReplicatedStorage = game:GetService('ReplicatedStorage')
local Packages = ReplicatedStorage:WaitForChild('Packages')
local FibersPackage = Packages:WaitForChild('Fibers')

local fibers = require(FibersPackage)
local Op = require(FibersPackage.op)
local Sleep = require(FibersPackage.sleep)
local Roblox = require(FibersPackage.roblox)

local continueButton = script.Parent:WaitForChild('ContinueButton')

local app
app = Roblox.attach(function()
  local pressed = Roblox.events(continueButton.Activated, {
    label = 'continue-button',
  })

  local outcome = fibers.perform(Op.named_choice({
    continued = pressed:next_op(),
    idle = Sleep.sleep_op(8),
  }))

  if outcome == 'continued' then
    print('The player continued.')
  else
    print('The prompt became idle.')
  end
end, {
  label = 'event-attached-button-choice',
  scheduling = 'event',
  max_seconds_per_turn = 0.001,
  on_status = function(status)
    if status.state ~= 'settled' or not app then
      return
    end

    local result = app:result()
    app:close()
    if not result.ok then
      warn('Fibers application failed', result)
    end
  end,
})

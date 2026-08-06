-- Manual phase-driven embedding: an existing Heartbeat loop owns when Fibers
-- advances and supplies a bounded execution horizon. The canonical part is the
-- prepare/advance boundary; applications which do not need frame-phase control
-- should normally use event-driven Roblox.attach instead.
--
-- Place this LocalScript beneath a ScreenGui containing a TextButton named
-- ContinueButton.

local RunService = game:GetService('RunService')
local ReplicatedStorage = game:GetService('ReplicatedStorage')
local Packages = ReplicatedStorage:WaitForChild('Packages')
local FibersPackage = Packages:WaitForChild('Fibers')

local fibers = require(FibersPackage)
local Op = require(FibersPackage.op)
local Sleep = require(FibersPackage.sleep)
local Roblox = require(FibersPackage.roblox)

local continueButton = script.Parent:WaitForChild('ContinueButton')

local app = Roblox.prepare(function()
  local pressed = Roblox.events(continueButton.Activated, {
    label = 'observatory-continue',
  })

  local outcome = fibers.perform(Op.named_choice({
    continued = pressed:next_op(),
    faded = Sleep.sleep_op(8),
  }))

  print('Observatory prompt exited through', outcome)
end, {
  label = 'manual-heartbeat-client',
  max_steps_per_turn = 128,
  max_work_per_step = 512,
})

local driver
driver = RunService.Heartbeat:Connect(function()
  local status = app:advance({
    -- Fibers may use at most one millisecond of this host turn before
    -- retaining its exact progress for the next frame.
    horizon = os.clock() + 0.001,
  })

  if status.state == 'settled' then
    driver:Disconnect()
    local result = app:result()
    app:close()
    if not result.ok then
      warn('Fibers application failed', result)
    end
  end
end)

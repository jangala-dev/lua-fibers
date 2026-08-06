-- A scene scope owns every activity required by the cinematic. Roblox.run
-- is event-attached convenience here; Roblox still owns scheduling. Replace
-- the placeholder functions with camera, animation, subtitle and audio work.

local ReplicatedStorage = game:GetService('ReplicatedStorage')
local Packages = ReplicatedStorage:WaitForChild('Packages')
local FibersPackage = Packages:WaitForChild('Fibers')

local fibers = require(FibersPackage)
local Op = require(FibersPackage.op)
local Sleep = require(FibersPackage.sleep)
local Roblox = require(FibersPackage.roblox)

local skipButton = script.Parent:WaitForChild('SkipButton')

local function playCameraTrack()
  fibers.perform(Sleep.sleep_op(4.5))
end

local function playDialogue()
  fibers.perform(Sleep.sleep_op(4))
end

Roblox.run(function()
  local exit = fibers.scope({ label = 'observatory-arrival' }, function(scene)
    local skipped = Roblox.events(skipButton.Activated, {
      label = 'skip-observatory-arrival',
    })

    local camera = scene:spawn(playCameraTrack):label('camera-track')
    local dialogue = scene:spawn(playDialogue):label('dialogue')

    local selected = fibers.perform(Op.named_choice({
      completed = Op.each({
        camera:body_result_op(),
        dialogue:body_result_op(),
      }),
      skipped = skipped:next_op(),
    }))

    if selected == 'skipped' then
      camera:request_cancel('player skipped')
      dialogue:request_cancel('player skipped')
    end

    return selected
  end)

  print('Cinematic exited through', exit)
end, {
  label = 'cinematic-client',
})

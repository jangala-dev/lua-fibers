-- Each player receives one structured lifetime. Roblox.run is event-attached
-- convenience; character observation, profile refresh and quest delivery cannot
-- outlive the owning player.

local Players = game:GetService('Players')
local ReplicatedStorage = game:GetService('ReplicatedStorage')
local Packages = ReplicatedStorage:WaitForChild('Packages')
local FibersPackage = Packages:WaitForChild('Fibers')

local fibers = require(FibersPackage)
local Roblox = require(FibersPackage.roblox)

local function servePlayer(player)
  return fibers.scope({ label = `player:{player.UserId}` }, function(session)
    local characterAdded = Roblox.events(player.CharacterAdded, {
      label = `character-added:{player.UserId}`,
    })
    local leaving = Roblox.events(player.Destroying, {
      label = `player-leaving:{player.UserId}`,
    })

    session:spawn(function()
      while true do
        local character = characterAdded:next()
        print('Observe character', character.Name)
      end
    end, 'character-lifetime')

    session:spawn(function()
      while true do
        -- Replace with a genuine profile-lock refresh operation.
        fibers.perform(require(FibersPackage.sleep).sleep_op(30))
      end
    end, 'profile-lock')

    leaving:next()
    return 'player left'
  end)
end

Roblox.run(function(root)
  Roblox.bind_to_close(root)

  local joined = Roblox.events(Players.PlayerAdded, { label = 'players-joined' })
  for _, player in Players:GetPlayers() do
    root:spawn(function()
      servePlayer(player)
    end, `player:{player.UserId}`)
  end

  while true do
    local player = joined:next()
    root:spawn(function()
      servePlayer(player)
    end, `player:{player.UserId}`)
  end
end, {
  label = 'player-sessions',
})

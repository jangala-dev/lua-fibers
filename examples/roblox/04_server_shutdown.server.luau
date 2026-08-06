-- BindToClose publishes one host fact. Roblox.try_run is event-attached
-- convenience; an owned Fibers monitor requests root cancellation, and Roblox
-- waits while the resulting scopes settle.

local ReplicatedStorage = game:GetService('ReplicatedStorage')
local Packages = ReplicatedStorage:WaitForChild('Packages')
local FibersPackage = Packages:WaitForChild('Fibers')

local fibers = require(FibersPackage)
local Op = require(FibersPackage.op)
local Sleep = require(FibersPackage.sleep)
local Roblox = require(FibersPackage.roblox)

local function runWorldSimulation()
  while true do
    fibers.perform(Sleep.sleep_op(1))
    -- advance one managed simulation step
  end
end

local result = Roblox.try_run(function(root)
  Roblox.bind_to_close(root, {
    deadline = 25,
    reason = 'Roblox server closing',
    on_timeout = function(reason)
      warn('Fibers shutdown deadline reached', reason)
    end,
  })

  root:spawn(runWorldSimulation):label('world-simulation')
  fibers.perform(Op.never())
end, {
  label = 'game-server',
})

if not result.ok and result.reason ~= 'cancelled' then
  warn('Game server ended unexpectedly', result.primary)
end

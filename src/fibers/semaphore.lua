local Counter = require('fibers.resource.counter')
local Direct = require('fibers.internal.direct')

local Semaphore = {}
Semaphore.__index = Semaphore
setmetatable(Semaphore, { __index = Counter })

function Semaphore.new(capacity)
  return setmetatable(Counter.bounded(capacity), Semaphore)
end

function Semaphore:acquire_op(amount) return self:take_op(amount) end
function Semaphore:release_op(amount) return self:give_op(amount) end
function Semaphore:available_op() return self:read_op() end

Direct.install(Semaphore, { 'acquire', 'release', 'available' })
return Semaphore

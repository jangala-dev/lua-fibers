local Counter = require('fibers.resource.counter')
local Label = require('fibers.internal.label')

local Semaphore = {}
Semaphore.__index = Semaphore
local next_id = 0

function Semaphore.new(capacity)
  next_id = next_id + 1
  local id = 'semaphore-' .. tostring(next_id)
  local semaphore = Label.attach(setmetatable({
    _fibers_id = id,
    _counter = Counter.bounded(capacity),
  }, Semaphore))
  Label.child(semaphore._counter, semaphore, 'capacity')
  return semaphore
end

function Semaphore:acquire_op(amount)
  return self._counter:take_op(amount)
end

function Semaphore:release_op(amount)
  return self._counter:give_op(amount)
end

function Semaphore:available_op()
  return self._counter:read_op()
end

function Semaphore:acquire(amount)
  return self._counter:take(amount)
end

function Semaphore:release(amount)
  return self._counter:give(amount)
end

function Semaphore:available()
  return self._counter:read()
end

return Semaphore

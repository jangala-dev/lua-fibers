local Counter = require('fibers.resource.counter')

local Semaphore = {}
Semaphore.__index = Semaphore

function Semaphore.new(capacity, name)
  return setmetatable({ _counter = Counter.bounded(capacity, name) }, Semaphore)
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

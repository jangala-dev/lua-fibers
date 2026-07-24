local FakeGame = {}
FakeGame.__index = FakeGame

function FakeGame.new(task_api)
  return setmetatable({ task = task_api, callbacks = {} }, FakeGame)
end

function FakeGame:BindToClose(fn)
  self.callbacks[#self.callbacks + 1] = fn
end

function FakeGame:close()
  for i = 1, #self.callbacks do
    self.task.defer(self.callbacks[i])
  end
end

return FakeGame

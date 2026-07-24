local FakeTask = {}
FakeTask.__index = FakeTask

local unpack_ = table.unpack or unpack

local function pack(...)
  return { n = select('#', ...), ... }
end

local function callable_thread(callable, args)
  if type(callable) == 'thread' then
    return callable, args
  end
  return coroutine.create(function()
    return callable(unpack_(args, 1, args.n))
  end), pack()
end

function FakeTask.new(start)
  local self = setmetatable({
    now = start or 0,
    _serial = 0,
    _scheduled = {},
    failures = {},
  }, FakeTask)

  self.api = {
    defer = function(callable, ...)
      return self:schedule(0, callable, ...)
    end,
    delay = function(delay, callable, ...)
      return self:schedule(delay, callable, ...)
    end,
    cancel = function(token)
      if token then
        token.cancelled = true
      end
    end,
    wait = function(delay)
      local started = self.now
      local co = coroutine.running()
      self:schedule(delay or 0, co)
      coroutine.yield()
      return self.now - started
    end,
  }
  return self
end

function FakeTask:schedule(delay, callable, ...)
  self._serial = self._serial + 1
  local input = pack(...)
  local thread, args = callable_thread(callable, input)
  local token = {
    at = self.now + math.max(0, tonumber(delay) or 0),
    serial = self._serial,
    thread = thread,
    args = args,
    cancelled = false,
  }
  self._scheduled[#self._scheduled + 1] = token
  return token
end

function FakeTask:resume(thread, ...)
  return self:schedule(0, thread, ...)
end

local function before(a, b)
  return a.at < b.at or a.at == b.at and a.serial < b.serial
end

function FakeTask:_take_next()
  local index, selected
  for i = 1, #self._scheduled do
    local item = self._scheduled[i]
    if not item.cancelled and (not selected or before(item, selected)) then
      index, selected = i, item
    end
  end
  if not selected then
    self._scheduled = {}
    return nil
  end
  table.remove(self._scheduled, index)
  return selected
end

function FakeTask:step()
  local item = self:_take_next()
  if not item then
    return false
  end
  self.now = math.max(self.now, item.at)
  local result = pack(coroutine.resume(item.thread, unpack_(item.args, 1, item.args.n)))
  if not result[1] then
    self.failures[#self.failures + 1] = result[2]
    error(result[2], 0)
  end
  return true
end

function FakeTask:run_until_idle(limit)
  limit = limit or 10000
  local steps = 0
  while self:step() do
    steps = steps + 1
    if steps > limit then
      error('fake Roblox scheduler exceeded step limit', 2)
    end
  end
  return steps
end

function FakeTask:run_until(predicate, limit)
  limit = limit or 10000
  local steps = 0
  while not predicate() do
    if not self:step() then
      return false
    end
    steps = steps + 1
    if steps > limit then
      error('fake Roblox scheduler exceeded step limit', 2)
    end
  end
  return true
end

return FakeTask

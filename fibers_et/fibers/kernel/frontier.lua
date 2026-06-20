-- Fine-grained invalidation frontiers.
--
-- A Frontier represents one mutable fact boundary.  Worlds, bounded-search
-- cursors, and cached outcomes observe frontiers.  When a resource mutation can
-- falsify that fact, the resource invalidates the frontier; all observers then
-- become invalid without re-walking their observations.

local Frontier = {}
Frontier.__index = Frontier

local Observer = {}
Observer.__index = Observer

function Frontier.new(name)
  return setmetatable({ name = name, gen = 0, observers = nil }, Frontier)
end

function Frontier:observe(observer)
  if not observer then return self.gen end
  if observer.valid == false then return self.gen end

  self.observers = self.observers or {}
  self.observers[observer] = true
  observer.frontiers = observer.frontiers or {}
  observer.frontiers[self] = true
  return self.gen
end

function Frontier:invalidate(reason)
  self.gen = (self.gen or 0) + 1
  local observers = self.observers
  if not observers then return end
  self.observers = nil
  for observer in pairs(observers) do
    observer:invalidate(self, reason)
  end
end

function Observer.new(kind, owner)
  return setmetatable({
    kind = kind,
    owner = owner,
    valid = true,
    frontiers = nil,
    invalidated_by = nil,
    invalidated_reason = nil,
  }, Observer)
end

function Observer:observe(frontier)
  if frontier then return frontier:observe(self) end
end

function Observer:invalidate(frontier, reason)
  if self.valid == false then return end
  self.valid = false
  self.invalidated_by = frontier
  self.invalidated_reason = reason
  local owner = self.owner
  if owner and owner.invalidate then owner:invalidate(frontier, reason) end
end

function Observer:dispose()
  local frontiers = self.frontiers
  if not frontiers then return end
  for frontier in pairs(frontiers) do
    local observers = frontier.observers
    if observers then observers[self] = nil end
  end
  self.frontiers = nil
end

return { Frontier = Frontier, Observer = Observer }

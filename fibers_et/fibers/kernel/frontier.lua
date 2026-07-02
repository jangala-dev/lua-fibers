-- Generation-stamped validity frontiers.
--
-- This experimental branch uses pull validation rather than push
-- invalidation.  A Frontier is a mutable fact boundary with a stamp.  Search
-- cursors and prepared worlds record the stamp they observed.  Before resuming
-- or committing, observers compare their recorded stamps with current stamps.
--
-- Resource authors should not manipulate Frontiers directly.  They should use
-- managed validity capabilities in fibers.kernel.validity.  This module is the
-- small substrate used by those capabilities and by the transaction net.

local Frontier = {}
Frontier.__index = Frontier

local Observer = {}
Observer.__index = Observer

function Frontier.new(name)
  return setmetatable({ name = name, gen = 0 }, Frontier)
end

function Frontier:observe(observer)
  if observer and observer.observe then observer:observe(self) end
  return self.gen or 0
end

function Frontier:invalidate(_reason)
  self.gen = (self.gen or 0) + 1
end

function Observer.new(kind, owner)
  return setmetatable({
    kind = kind,
    owner = owner,
    valid = true,
    observations = nil,
    index = nil,
    invalidated_by = nil,
    invalidated_reason = nil,
  }, Observer)
end

function Observer:observe(frontier)
  if not frontier then return nil end
  if self.valid == false then return frontier.gen or 0 end
  local index = self.index
  if not index then index = {}; self.index = index; self.observations = {} end
  local gen = index[frontier]
  if gen ~= nil then return gen end
  gen = frontier.gen or 0
  index[frontier] = gen
  -- Store frontiers directly.  The stamp lives in `index[frontier]`, avoiding a
  -- per-observation record table on validity-heavy search paths.
  self.observations[#self.observations + 1] = frontier
  return gen
end

function Observer:validate()
  if self.valid == false then return false end
  local observations = self.observations
  if not observations then return true end
  local index = self.index or {}
  for i = 1, #observations do
    local frontier = observations[i]
    local gen = index[frontier]
    if frontier and (frontier.gen or 0) ~= gen then
      self.valid = false
      self.invalidated_by = frontier
      self.invalidated_reason = 'frontier-stamp-changed'
      return false
    end
  end
  return true
end

function Observer:invalidate(frontier, reason)
  -- Kept for internal callers that explicitly poison an observer.  Frontier
  -- changes themselves no longer push into observers.
  if self.valid == false then return end
  self.valid = false
  self.invalidated_by = frontier
  self.invalidated_reason = reason
end

function Observer:dispose()
  self.observations = nil
  self.index = nil
end

return { Frontier = Frontier, Observer = Observer }

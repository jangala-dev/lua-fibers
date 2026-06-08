-- Interrupt tokens are perform-boundary capabilities.
--
-- They are deliberately not Ops and not Sources.  A policy may attach one to a
-- perform boundary; an after-commit interrupt Effect raises it and wakes any
-- parked attempts that registered with it.

local Interrupt = {}
Interrupt.__index = Interrupt

local next_id = 0

function Interrupt.new(name)
  next_id = next_id + 1
  local id = 'interrupt-' .. tostring(next_id)
  return setmetatable({
    name = name or id,
    version = 0,
    raised = false,
    reason = nil,
    _fibers_id = id,
    _fibers_interrupt = true,
  }, Interrupt)
end

function Interrupt:is_raised()
  return self.raised == true
end

function Interrupt:raise(reason)
  self.raised = true
  self.reason = reason
  self.version = (self.version or 0) + 1
  return true
end

function Interrupt:clear()
  self.raised = false
  self.reason = nil
  self.version = (self.version or 0) + 1
  return true
end

return Interrupt

-- Internal interrupt tokens for perform-boundary cancellation.
--
-- Public code obtains cancellation through Task/Scope options.  Raw token
-- mutation is only used by the runtime when discharging a committed interrupt
-- Effect.

local Interrupt = {}

local Token = {}
Token.__index = Token

local next_id = 0

function Token:is_raised()
  return self.raised == true
end

function Interrupt.new(name)
  next_id = next_id + 1
  local id = 'interrupt-' .. tostring(next_id)
  local token = setmetatable({
    name = name or id,
    version = 0,
    raised = false,
    reason = nil,
    _fibers_id = id,
    _fibers_interrupt = true,
  }, Token)
  return token
end

function Interrupt.raise(token, reason)
  if type(token) ~= 'table' or token._fibers_interrupt ~= true then error('Interrupt.raise expects an interrupt token', 2) end
  token.raised = true
  token.reason = reason
  token.version = (token.version or 0) + 1
  return true
end

return Interrupt

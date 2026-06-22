-- Proof-search artefacts shared by the transaction net and resources.
--
-- Capture describes which proof observations a search should retain.
-- AbsenceCert records the debug observations explaining a certified miss.

local Proof = {}

local Capture = {}
Capture.__index = Capture

function Capture.new(opts)
  opts = opts or {}
  return setmetatable({ retain_frontiers = opts.frontiers == true, retain_debug = opts.debug == true }, Capture)
end

function Capture.none()
  return Capture.new()
end

function Capture.frontiers()
  return Capture.new({ frontiers = true })
end

function Capture.debug()
  return Capture.new({ frontiers = true, debug = true })
end

function Capture:frontiers_enabled()
  return self and self.retain_frontiers == true
end

function Capture:debug_enabled()
  return self and self.retain_debug == true
end

local AbsenceCert = {}
AbsenceCert.__index = AbsenceCert

function AbsenceCert.new(items)
  local self = setmetatable({}, AbsenceCert)
  if items then self:extend(items) end
  return self
end

function AbsenceCert:add(obs)
  if obs then self[#self + 1] = obs end
  return self
end

function AbsenceCert:extend(other)
  if not other then return self end
  for i = 1, #other do self:add(other[i]) end
  return self
end

function AbsenceCert:is_empty()
  return #self == 0
end

function AbsenceCert:debug_observations()
  return self
end

Proof.Capture = Capture
Proof.AbsenceCert = AbsenceCert

return Proof

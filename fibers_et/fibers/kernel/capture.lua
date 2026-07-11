-- Controls which proof-search observations are retained beyond the hot path.

local Capture = {}
Capture.__index = Capture

function Capture.new(opts)
  opts = opts or {}
  return setmetatable({
    retain_frontiers = opts.frontiers == true,
    retain_debug = opts.debug == true,
  }, Capture)
end

function Capture.none() return Capture.new() end
function Capture.frontiers() return Capture.new({ frontiers = true }) end
function Capture.debug() return Capture.new({ frontiers = true, debug = true }) end
function Capture:frontiers_enabled() return self and self.retain_frontiers == true end
function Capture:debug_enabled() return self and self.retain_debug == true end

return Capture

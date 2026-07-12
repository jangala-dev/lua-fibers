local Claim = {}
local next_claim = 0

function Claim.new(region, root, records, purpose)
  next_claim = next_claim + 1
  return {
    _fibers_claim = true,
    _fibers_value = true,
    id = 'claim-' .. tostring(next_claim),
    region = region,
    root = root,
    records = records,
    purpose = purpose,
    reason = type(purpose) == 'table' and purpose.reason or nil,
  }
end

function Claim.is(x)
  return type(x) == 'table' and x._fibers_claim == true
end

return Claim
